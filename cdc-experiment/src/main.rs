use std::collections::BTreeMap;
use std::fs::File;
use std::io::{BufReader, Read};

fn open_decompressed(path: &str) -> Box<dyn Read> {
    let mut f = File::open(path).expect("open blob");
    let mut magic = [0u8; 4];
    use std::io::Seek;
    let n = f.read(&mut magic).unwrap_or(0);
    f.seek(std::io::SeekFrom::Start(0)).unwrap();
    let r = BufReader::with_capacity(1 << 20, f);
    if n >= 4 && magic == [0x28, 0xb5, 0x2f, 0xfd] {
        Box::new(zstd::stream::read::Decoder::new(r).expect("zstd"))
    } else if n >= 2 && magic[0] == 0x1f && magic[1] == 0x8b {
        Box::new(flate2::read::GzDecoder::new(r))
    } else {
        Box::new(r)
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mode = args.get(1).map(String::as_str).unwrap_or("");
    let path = args.get(2).expect("usage: cdc-tool <chunk|paths> <blob> [avg_size]");
    match mode {
        "chunk" => {
            let avg: u32 = args.get(3).map(|s| s.parse().unwrap()).unwrap_or(65536);
            let reader = open_decompressed(path);
            let chunker = fastcdc::v2020::StreamCDC::new(reader, avg / 4, avg, avg * 4);
            let mut total: u64 = 0;
            let mut count: u64 = 0;
            use sha2::Digest;
            let stdout = std::io::stdout();
            let mut out = std::io::BufWriter::new(stdout.lock());
            use std::io::Write;
            for result in chunker {
                let chunk = result.expect("chunk read");
                let hash = sha2::Sha256::digest(&chunk.data);
                total += chunk.length as u64;
                count += 1;
                writeln!(out, "C {:x} {}", hash, chunk.length).unwrap();
            }
            writeln!(out, "T {} {}", total, count).unwrap();
        }

        "filechunk" => {
            let avg: u32 = args.get(3).map(|s| s.parse().unwrap()).unwrap_or(65536);
            let reader = open_decompressed(path);
            let mut archive = tar::Archive::new(reader);
            use sha2::Digest;
            let stdout = std::io::stdout();
            let mut out = std::io::BufWriter::new(stdout.lock());
            use std::io::Write;
            let mut content_total: u64 = 0;
            let mut header_total: u64 = 0;
            let mut count: u64 = 0;
            if let Ok(entries) = archive.entries() {
                for entry in entries {
                    let Ok(entry) = entry else { break };
                    header_total += 512;
                    let size = entry.size();
                    if size == 0 { continue; }
                    content_total += size;
                    let chunker = fastcdc::v2020::StreamCDC::new(entry, avg / 4, avg, avg * 4);
                    for result in chunker {
                        let Ok(chunk) = result else { break };
                        let hash = sha2::Sha256::digest(&chunk.data);
                        count += 1;
                        writeln!(out, "C {:x} {}", hash, chunk.length).unwrap();
                    }
                }
            }
            writeln!(out, "T {} {} headers={}", content_total, count, header_total).unwrap();
        }
        "recompress" => {
            // decompress -> zstd-3 over ALL bytes: today's publish CPU over a
            // changed set (baseline against `novel` for CDC's compute delta)
            struct CountWriter2(u64);
            impl std::io::Write for CountWriter2 {
                fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
                    self.0 += buf.len() as u64;
                    Ok(buf.len())
                }
                fn flush(&mut self) -> std::io::Result<()> { Ok(()) }
            }
            use std::io::Write;
            let mut reader = open_decompressed(path);
            let mut enc = zstd::stream::write::Encoder::new(CountWriter2(0), 3).expect("zstd enc");
            let mut buf = [0u8; 1 << 20];
            let mut total: u64 = 0;
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => { total += n as u64; enc.write_all(&buf[..n]).unwrap(); }
                    Err(_) => break,
                }
            }
            let counter = enc.finish().expect("zstd finish");
            println!("W {} T {}", counter.0, total);
        }
        "drain" => {
            // decompress and count only - baseline for chunking-cost deltas
            let mut reader = open_decompressed(path);
            let mut buf = [0u8; 1 << 20];
            let mut total: u64 = 0;
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => total += n as u64,
                    Err(_) => break,
                }
            }
            println!("T {}", total);
        }
        "paths" => {
            let reader = open_decompressed(path);
            let mut archive = tar::Archive::new(reader);
            let mut by_prefix: BTreeMap<String, u64> = BTreeMap::new();
            match archive.entries() {
                Ok(entries) => {
                    for entry in entries {
                        let Ok(entry) = entry else { break };
                        let size = entry.size();
                        let p = entry.path().ok().map(|p| p.display().to_string()).unwrap_or_default();
                        let comps: Vec<&str> = p.trim_start_matches("./").split('/').filter(|c| !c.is_empty()).collect();
                        let prefix = match comps.len() {
                            0 => String::from("(root)"),
                            1 => comps[0].to_string(),
                            _ => format!("{}/{}", comps[0], comps[1]),
                        };
                        *by_prefix.entry(prefix).or_insert(0) += size;
                    }
                }
                Err(_) => {}
            }
            let mut v: Vec<(String, u64)> = by_prefix.into_iter().collect();
            v.sort_by(|a, b| b.1.cmp(&a.1));
            for (prefix, bytes) in v.into_iter().take(12) {
                println!("P {} {}", prefix, bytes);
            }
        }
        "novel" => {
            // novel <blob> <avg> <store_hash_file>: chunk the blob, batch the
            // chunks NOT in the store through zstd-3 (the wire payload a CDC
            // upload would carry) and print W <wire> N <novel> T <total>.
            let avg: u32 = args.get(3).map(|s| s.parse().unwrap()).unwrap_or(65536);
            let store_path = args.get(4).expect("novel mode needs <store_hash_file>");
            let store: std::collections::HashSet<String> =
                std::fs::read_to_string(store_path)
                    .expect("read store file")
                    .lines()
                    .map(|l| l.trim().to_string())
                    .filter(|l| !l.is_empty())
                    .collect();
            struct CountWriter(u64);
            impl std::io::Write for CountWriter {
                fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
                    self.0 += buf.len() as u64;
                    Ok(buf.len())
                }
                fn flush(&mut self) -> std::io::Result<()> { Ok(()) }
            }
            let reader = open_decompressed(path);
            let chunker = fastcdc::v2020::StreamCDC::new(reader, avg / 4, avg, avg * 4);
            use sha2::Digest;
            use std::io::Write;
            let mut enc = zstd::stream::write::Encoder::new(CountWriter(0), 3).expect("zstd enc");
            let mut novel: u64 = 0;
            let mut total: u64 = 0;
            for result in chunker {
                let chunk = result.expect("chunk read");
                let hash = format!("{:x}", sha2::Sha256::digest(&chunk.data));
                total += chunk.length as u64;
                if !store.contains(&hash) {
                    novel += chunk.length as u64;
                    enc.write_all(&chunk.data).unwrap();
                }
            }
            let counter = enc.finish().expect("zstd finish");
            println!("W {} N {} T {}", counter.0, novel, total);
        }
        _ => eprintln!("usage: cdc-tool <chunk|filechunk|paths|novel> <blob> [avg_size] [store_hash_file]"),
    }
}
