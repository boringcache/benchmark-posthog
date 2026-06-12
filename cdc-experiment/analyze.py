#!/usr/bin/env python3
"""CDC falsifying experiment: cross-run chunk dedup on real BuildKit layer blobs.

Usage: analyze.py <runA_oci_dir> <runB_oci_dir> [avg_chunk_size]
Each dir is a `boringcache restore`d OCI layout (blobs/sha256/*).
Measures, for blobs present in B but not A (the bytes BuildKit re-uploads today):
  - naive stream FastCDC dedup vs all of run A's chunks
  - file-aware (tar-split ceiling) dedup vs run A's file-aware chunks
Reports per layer class and totals.
"""
import json, os, subprocess, sys, collections

TOOL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "target/release/cdc-tool")

def is_layer(path):
    with open(path, "rb") as f:
        magic = f.read(4)
    return magic[:4] == b"\x28\xb5\x2f\xfd" or magic[:2] == b"\x1f\x8b"

def blobs(d):
    root = os.path.join(d, "blobs", "sha256")
    out = {}
    for name in os.listdir(root):
        p = os.path.join(root, name)
        if os.path.isfile(p) and is_layer(p):
            out[name] = p
    return out

def run_tool(mode, path, avg):
    res = subprocess.run([TOOL, mode, path, str(avg)], capture_output=True, text=True)
    chunks, total = [], 0
    for line in res.stdout.splitlines():
        parts = line.split()
        if parts and parts[0] == "C":
            chunks.append((parts[1], int(parts[2])))
        elif parts and parts[0] == "T":
            total = int(parts[1])
    return chunks, total

def classify(path):
    res = subprocess.run([TOOL, "paths", path], capture_output=True, text=True)
    prefixes = [l.split()[1] for l in res.stdout.splitlines() if l.startswith("P ")][:6]
    joined = " ".join(prefixes)
    if "node_modules" in joined or "pnpm" in joined or ".pnpm" in joined: return "node_modules"
    if "python-runtime" in joined or "site-packages" in joined or ".venv" in joined or "uv" in joined: return "python"
    if "var/lib" in joined or "usr/share" in joined or "usr/lib" in joined or "etc/" in joined: return "os/apt"
    if "frontend" in joined or "static" in joined or "dist" in joined: return "frontend-assets"
    return f"other({prefixes[0] if prefixes else '?'})"

def main():
    run_a, run_b = sys.argv[1], sys.argv[2]
    avg = int(sys.argv[3]) if len(sys.argv) > 3 else 65536
    A, B = blobs(run_a), blobs(run_b)
    shared_digests = set(A) & set(B)
    changed = {d: p for d, p in B.items() if d not in A}
    print(f"run A blobs: {len(A)}  run B blobs: {len(B)}  identical digests: {len(shared_digests)}")
    print(f"changed blobs in B (re-uploaded today): {len(changed)}")
    exact_free = sum(os.path.getsize(B[d]) for d in shared_digests)
    changed_compressed = sum(os.path.getsize(p) for p in changed.values())
    print(f"compressed bytes: free-today {exact_free/1e6:.0f}MB, re-uploaded {changed_compressed/1e6:.0f}MB")

    store = {"chunk": set(), "filechunk": set()}
    for mode in store:
        for p in A.values():
            for h, _ in run_tool(mode, p, avg)[0]:
                store[mode].add(h)

    cls_stats = collections.defaultdict(lambda: [0, 0, 0])  # total, naive_shared, file_shared
    for digest, p in sorted(changed.items()):
        cls = classify(p)
        n_chunks, n_total = run_tool("chunk", p, avg)
        f_chunks, f_total = run_tool("filechunk", p, avg)
        n_shared = sum(l for h, l in n_chunks if h in store["chunk"])
        f_shared = sum(l for h, l in f_chunks if h in store["filechunk"])
        cls_stats[cls][0] += n_total
        cls_stats[cls][1] += n_shared
        cls_stats[cls][2] += f_shared
        print(f"  {digest[:12]} {cls:18s} uncomp={n_total/1e6:8.1f}MB naive={100*n_shared/max(n_total,1):5.1f}% file-aware={100*f_shared/max(f_total,1):5.1f}%")

    print(f"\n== per-class dedup of changed blobs (avg chunk {avg//1024}K) ==")
    tt = tn = tf = 0
    for cls, (tot, n, f) in sorted(cls_stats.items(), key=lambda kv: -kv[1][0]):
        tt += tot; tn += n; tf += f
        print(f"  {cls:18s} {tot/1e6:9.1f}MB  naive {100*n/max(tot,1):5.1f}%  file-aware {100*f/max(tot,1):5.1f}%")
    print(f"  {'TOTAL':18s} {tt/1e6:9.1f}MB  naive {100*tn/max(tt,1):5.1f}%  file-aware {100*tf/max(tt,1):5.1f}%")
    print("\nverdict guide: naive>=70% -> CDC pays as-is; naive<40% but file-aware high -> needs tar-aware chunking; both low -> content truly churns, CDC does not pay")

if __name__ == "__main__":
    main()
