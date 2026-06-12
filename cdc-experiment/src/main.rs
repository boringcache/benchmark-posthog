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
        _ => eprintln!("usage: cdc-tool <chunk|paths> <blob> [avg_size]"),
    }
}
