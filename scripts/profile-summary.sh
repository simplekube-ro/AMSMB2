#!/bin/bash
# Summarise an Instruments capture of the AMSMB2 inbound path without the Instruments GUI.
#
# Usage: scripts/profile-summary.sh [--pairing per-thread|global] <bundle.trace | export-dir>
#
#   --pairing     how TransportRead events are paired to InboundChunk events for the pump-hop
#                 latency: per-thread (default; captures of 6.0.0-rc5 or later, where a read and
#                 its chunk are emitted back to back on the delivery thread) or global (the
#                 byte-sum FIFO across threads, for captures taken before the inbound
#                 push-conversion, #45, such as the rc4 Baseline bundles). The mode used is
#                 printed in the output.
#   bundle.trace  exported with `xcrun xctrace export --xpath` (time-profile and os-signpost
#                 tables) into a temp dir, then summarised
#   export-dir    a directory holding time-profile.xml (required) and os-signpost.xml
#                 (optional), e.g. test-fixtures/profiling/sample-export
#
# Output (plain text, deterministic): total samples and a per-thread table, then per signpost
# name under subsystem ro.SimpleKube.AMSMB2 the count, byte totals and size percentiles
# (TransportRead, InboundChunk, RecvDrain), the InboundChunk ceiling line, duration percentiles
# (ServiceDispatch, ServicePass; terminal passes listed separately and excluded), the coalescing
# ratio, the pairing mode, pump-hop latency, bytes still buffered, and derived throughput. See
# docs/PROFILING.md for the metric definitions.
#
# Conventions:
#   - Percentiles use nearest-rank: over the N sorted values, pN is the value at 1-based index
#     ceil(N * p / 100); median is p50. Sizes are bytes; durations are milliseconds (3 decimals).
#   - A thread is labelled "<name> (0x<tid>)", i.e. xctrace's thread label with the trailing
#     "(<process>, pid: N)" removed; unnamed threads therefore appear under the process name.
#   - InboundChunk ceiling: printed after the InboundChunk size line — the number of chunks
#     whose size equals the maximum observed size, their share of the chunk count (3 decimals)
#     and of the byte total (2 decimals), then the share of chunks and of bytes at or above
#     65536, 131072, 262144, 524288 and 1048576 bytes. The thresholds are fixed so the line is
#     comparable across captures; the shares are finer than the per-thread table's 1 decimal
#     because an at-cap chunk share is a fraction of a percent while its byte share is whole
#     percents. With no InboundChunk events the line reads "ceiling: n/a". Caveat: it measures
#     the transport's receive length only where the coalescing ratio is 1.00 (a TCP capture of
#     6.0.0-rc5 or later, where each read is forwarded as exactly one chunk); on a coalesced
#     capture, or one whose chunks came from a transport that emits no TransportRead, the
#     maximum is a coalesced maximum. See "Receive length (#46)" in docs/PROFILING.md.
#   - RecvDrain: size stats cover drains that copied bytes; 0 (EOF) and -1 (would-block) are
#     counted separately. -1 arrives from xctrace as uint64 18446744073709551615 and is folded
#     back to a signed value.
#   - Pump-hop pairing, per-thread mode: TransportRead and InboundChunk events are walked in
#     timestamp order keyed by the emitting thread (the row's <thread><tid>), with at most one
#     read pending per thread. A chunk pairs with the pending read of equal bytes (latency =
#     chunk.ts - read.ts). A chunk with no read pending on its thread is a "chunk without a
#     read" (attach carry-over, a read signpost the recorder dropped, or a QUIC chunk); a read
#     superseded by another read on its thread, or still pending at the end, is a "read without
#     a chunk" (the teardown race). Both are counted, not errors. A chunk whose pending read has
#     different bytes is a pairing error that consumes both events. So every chunk is exactly one
#     of paired / without a read / error, and every non-zero read one of paired / without a
#     chunk / error. The pairing line also gives the number of distinct threads that emitted
#     either event ("delivery threads").
#   - Pump-hop pairing, global mode: for each InboundChunk of S bytes, TransportReads are popped
#     from one FIFO across all threads until they sum to S; latency = chunk.ts - first popped
#     read.ts. Overshoot or FIFO underflow is printed as a pairing error and counted, not fatal;
#     the reads-per-chunk distribution is printed. Zero-byte reads are skipped and counted in
#     both modes.
#   - Throughput = RecvDrain bytes / (last - first subsystem signpost timestamp), MB = 10^6 bytes.
#     Active throughput divides by the active time instead: the sum of the gaps between
#     consecutive subsystem signposts (all names, timestamp order) that are <= 1 s, so a burst
#     followed by a long keepalive-only stretch is measured over the burst.
#   - Signpost row order within one export follows the table's timestamp order; Begin/End are
#     paired by (name, signpost id) in that order.
#
# Exit status: 0 on success (including "no signposts"); 1 with a one-line message on stderr when
# the input is not readable, has no time-profile table, a signpost row of the subsystem carries
# no thread, the pairing mode is unknown, or the xctrace export fails.
set -euo pipefail

SUBSYSTEM="ro.SimpleKube.AMSMB2"
TP_XPATH='/trace-toc/run[1]/data/table[@schema="time-profile"]'
SP_XPATH='/trace-toc/run[1]/data/table[@schema="os-signpost"]'

die() { echo "error: $*" >&2; exit 1; }

usage="usage: $0 [--pairing per-thread|global] <bundle.trace | export-dir>"
pairing="per-thread"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pairing)
            [[ $# -ge 2 ]] || die "--pairing needs a value; $usage"
            pairing="$2"
            shift 2
            ;;
        -*) die "unknown option $1; $usage" ;;
        *) break ;;
    esac
done
case "$pairing" in
    per-thread | global) ;;
    *) die "unknown pairing mode '$pairing'; $usage" ;;
esac
[[ $# -eq 1 ]] || die "$usage"
input="$1"

tmpdir=""
cleanup() { if [[ -n "$tmpdir" ]]; then rm -rf "$tmpdir"; fi; }
trap cleanup EXIT

# export_table <name> <xpath>: export one table of the bundle to $export_dir/<name>.xml.
# xctrace writes to stdout when --output is omitted, but crashes if stdout is a closed pipe,
# so always export to a file.
# xctrace 16.0 segfaults (exit 139) on roughly one invocation in three against real bundles;
# that status alone is retried up to 3 attempts.
export_table() {
    local name="$1" xpath="$2"
    local status=0 attempt
    for attempt in 1 2 3; do
        status=0
        xcrun xctrace export --input "$input" --xpath "$xpath" \
            --output "$export_dir/$name.xml" >"$tmpdir/$name.log" 2>&1 || status=$?
        [[ $status -eq 139 && $attempt -lt 3 ]] || break
        echo "xctrace export of the $name table crashed (exit 139), retrying ($attempt/3)" >&2
    done
    if [[ $status -ne 0 ]]; then
        # a crash leaves the log empty, so always name the status
        die "xctrace export of the $name table failed for $input (exit $status):" \
            "$(tail -n 1 "$tmpdir/$name.log")"
    fi
}

if [[ "$input" == *.trace && -d "$input" ]]; then
    tmpdir="$(mktemp -d)"
    export_dir="$tmpdir"
    export_table time-profile "$TP_XPATH"
    export_table os-signpost "$SP_XPATH"
elif [[ -d "$input" ]]; then
    export_dir="$input"
    [[ -r "$export_dir/time-profile.xml" ]] || die "$input has no readable time-profile.xml (not an export directory?)"
else
    die "$input is neither a .trace bundle nor an export directory"
fi

python3 - "$export_dir" "$SUBSYSTEM" "$pairing" <<'PY'
import math
import os
import re
import sys
from collections import Counter, deque
import xml.etree.ElementTree as ET

export_dir, subsystem, pairing = sys.argv[1], sys.argv[2], sys.argv[3]

NS = 1_000_000_000
IDLE_GAP_NS = NS  # gaps longer than this between signposts do not count as active time
BYTE_EVENTS = ("TransportRead", "InboundChunk", "RecvDrain")
INTERVALS = ("ServiceDispatch", "ServicePass")
CEILING_THRESHOLDS = (65536, 131072, 262144, 524288, 1048576)  # the #46 sweep bounds, fixed


class Fail(Exception):
    pass


# --- xctrace export parsing ------------------------------------------------------------------

def load_table(path, schema, required):
    """Return (rows, resolve) for the `schema` table: the rows of every <node>, cell
    back-references resolved, plus the resolver for references nested inside a cell.

    Each row is a dict mnemonic -> element (the element carrying the value, or None for an
    empty <sentinel/> cell).
    """
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError) as e:
        raise Fail(f"{path}: {e}")
    by_id = {e.get("id"): e for e in root.iter() if e.get("id") is not None}

    def resolve(el):
        ref = el.get("ref")
        if ref is None:
            return el
        if ref not in by_id:
            raise Fail(f"{path}: unresolved back-reference ref=\"{ref}\"")
        return by_id[ref]

    # A real export spreads one table over several <node>s and only one of them carries
    # <schema>; the xpath guarantees every node belongs to the requested schema, so read the
    # columns once and take rows from every node regardless of order.
    nodes = root.findall("node")
    schemas = [n.find("schema") for n in nodes]
    sch = next((x for x in schemas if x is not None and x.get("name") == schema), None)
    if sch is None:
        if any(n.find("row") is not None for n in nodes):
            raise Fail(f"{path}: {schema} rows with no schema definition")
        return [], resolve
    cols = [c.findtext("mnemonic") for c in sch.findall("col")]
    missing = [m for m in required if m not in cols]
    if missing:
        raise Fail(f"{path}: {schema} table lacks column(s) {', '.join(missing)}; "
                   f"got {', '.join(cols)}")
    rows = []
    for node in nodes:
        for row in node.findall("row"):
            cells = list(row)
            if len(cells) != len(cols):
                raise Fail(f"{path}: {schema} row has {len(cells)} cells for {len(cols)} columns")
            rows.append({m: (None if c.tag == "sentinel" else resolve(c))
                         for m, c in zip(cols, cells)})
    return rows, resolve


def text_int(el, what):
    try:
        return int(el.text.strip())
    except (AttributeError, ValueError):
        raise Fail(f"cannot read an integer {what} from <{getattr(el, 'tag', '?')}>")


def thread_label(el):
    fmt = el.get("fmt", "")
    m = re.match(r"^(.*\(0x[0-9a-fA-F]+\)) \(.*, pid: \d+\)$", fmt)
    return m.group(1) if m else fmt


def message_value(el, resolve):
    """First integer argument of an <os-log-metadata> cell, or None; uint64 folded to signed.

    Argument values are interned inside the cell too (<uint64 ref="N"/>), hence `resolve`.
    """
    if el is None:
        return None
    for child in el:
        child = resolve(child)
        if child.tag in ("uint64", "int64", "uint32", "int32", "uint16", "int16", "uint8", "int8"):
            v = text_int(child, "signpost argument")
            if child.tag == "uint64" and v >= 1 << 63:
                v -= 1 << 64
            return v
    return None


# --- statistics ------------------------------------------------------------------------------

def nearest_rank(sorted_values, p):
    return sorted_values[max(0, math.ceil(len(sorted_values) * p / 100) - 1)]


def stats(values, fmt):
    if not values:
        return "n/a"
    s = sorted(values)
    return "min {} / median {} / p95 {} / max {}".format(
        fmt(s[0]), fmt(nearest_rank(s, 50)), fmt(nearest_rank(s, 95)), fmt(s[-1]))


def ms(ns):
    return f"{ns / 1_000_000:.3f}"


def ceiling(values):
    """Saturation of a chunk-size distribution: the at-max count with its chunk and byte shares,
    then the shares at or above each fixed threshold. See the header's Conventions for the
    rounding and for what the line does and does not measure.
    """
    if not values:
        return "n/a"
    count, total = len(values), sum(values)

    def shares(subset):
        """(share of the chunk count, share of the byte total) of a subset, as percents."""
        byte_share = 100.0 * sum(subset) / total if total else 0.0
        return f"{100.0 * len(subset) / count:.3f}%", f"{byte_share:.2f}%"

    largest = max(values)
    at_max = [v for v in values if v == largest]
    at_max_chunks, at_max_bytes = shares(at_max)
    above = []
    for threshold in CEILING_THRESHOLDS:
        chunk_share, byte_share = shares([v for v in values if v >= threshold])
        above.append(f"{threshold}: {chunk_share} / {byte_share}")
    return (f"{len(at_max)} chunks at the max size {largest} "
            f"({at_max_chunks} of chunks, {at_max_bytes} of bytes); "
            f"at or above {', '.join(above)}")


# --- pump-hop pairing ------------------------------------------------------------------------
# Both take the TransportRead and InboundChunk events in (ts, order) order and return the
# latencies (ns) plus the counts described in the header's Conventions.

def pair_per_thread(events):
    """One pending read per thread; a chunk pairs with its thread's pending read of equal bytes.

    Returns (latencies, chunks without a read, reads without a chunk, errors, zero-byte reads).
    """
    pending = {}  # tid -> (ts, bytes) of the read waiting for its chunk
    latencies, errors = [], []
    without_read = without_chunk = skipped_zero = 0
    for ts, _, name, _, _, value, tid, label in events:
        if name == "TransportRead":
            if value == 0:
                skipped_zero += 1
            else:
                if tid in pending:
                    without_chunk += 1
                pending[tid] = (ts, value)
            continue
        read = pending.pop(tid, None)
        if read is None:
            without_read += 1
        elif read[1] == value:
            latencies.append(ts - read[0])
        else:
            errors.append(f"mismatch: InboundChunk {value} bytes at {ts} ns on {label}, "
                          f"pending TransportRead {read[1]} bytes")
    without_chunk += len(pending)
    return latencies, without_read, without_chunk, errors, skipped_zero


def pair_global(events):
    """Pop reads from one FIFO across threads until their bytes sum to each chunk.

    Returns (latencies, reads-per-chunk Counter, errors, zero-byte reads).
    """
    fifo = deque()
    latencies, errors = [], []
    reads_per_chunk = Counter()
    skipped_zero = 0
    for ts, _, name, _, _, value, _, _ in events:
        if name == "TransportRead":
            if value == 0:
                skipped_zero += 1
            else:
                fifo.append((ts, value))
            continue
        acc, n, first_ts = 0, 0, None
        while acc < value and fifo:
            rts, rbytes = fifo.popleft()
            first_ts = rts if first_ts is None else first_ts
            acc += rbytes
            n += 1
        if acc == value and n:
            latencies.append(ts - first_ts)
            reads_per_chunk[n] += 1
        elif acc > value:
            errors.append(f"overshoot: InboundChunk {value} bytes at {ts} ns, {n} reads sum to {acc}")
        else:
            errors.append(f"underflow: InboundChunk {value} bytes at {ts} ns, only {acc} TransportRead bytes queued")
    return latencies, reads_per_chunk, errors, skipped_zero


def main():
    # --- time profile ----------------------------------------------------------------------------

    tp_path = os.path.join(export_dir, "time-profile.xml")
    tp_rows, _ = load_table(tp_path, "time-profile", required=("thread",))
    if not tp_rows:
        raise Fail(f"{tp_path}: no time-profile table with samples (was the Time Profiler instrument recording?)")

    samples = Counter()
    for row in tp_rows:
        th = row["thread"]
        if th is None:
            raise Fail(f"{tp_path}: time-profile row without a thread")
        samples[thread_label(th)] += 1
    total = sum(samples.values())

    print(f"Time profile: {total} samples")
    print(f"  {'samples':>7}  {'share':>6}  thread")
    for name, n in sorted(samples.items(), key=lambda kv: (-kv[1], kv[0])):
        print(f"  {n:>7}  {100.0 * n / total:>5.1f}%  {name}")

    # --- signposts -------------------------------------------------------------------------------

    sp_path = os.path.join(export_dir, "os-signpost.xml")
    events = []  # (ts, order, name, kind, ident, value, tid, thread label)
    ignored = 0
    if os.path.isfile(sp_path):
        sp_rows, resolve = load_table(sp_path, "os-signpost",
                             required=("time", "thread", "event-type", "identifier", "name", "subsystem", "message"))
        for order, row in enumerate(sp_rows):
            sub = row["subsystem"]
            if sub is None or (sub.text or "").strip() != subsystem:
                ignored += 1
                continue
            for col in ("time", "thread", "event-type", "identifier", "name"):
                if row[col] is None:
                    raise Fail(f"{sp_path}: signpost row {order + 1} has an empty {col} cell")
            tid = row["thread"].find("tid")
            if tid is None:
                raise Fail(f"{sp_path}: signpost row {order + 1} has a thread without a tid")
            events.append((
                text_int(row["time"], "timestamp"),
                order,
                (row["name"].text or "").strip(),
                (row["event-type"].text or "").strip(),
                (row["identifier"].text or "").strip(),
                message_value(row["message"], resolve),
                (resolve(tid).text or "").strip(),
                thread_label(row["thread"]),
            ))

    print()
    if not events:
        print(f"no {subsystem} signposts")
        sys.exit(0)

    events.sort(key=lambda e: (e[0], e[1]))
    plural = "s" if ignored != 1 else ""
    print(f"Signposts (subsystem {subsystem}): {len(events)} rows, "
          f"{ignored} row{plural} from other subsystems ignored")

    by_name = {}
    for ev in events:
        by_name.setdefault(ev[2], []).append(ev)

    # Byte-carrying events.
    sizes = {}
    for name in BYTE_EVENTS:
        vals = []
        for ev in by_name.get(name, []):
            if ev[3] != "Event":
                raise Fail(f"{name} row at {ev[0]} ns is a {ev[3]}, expected an Event")
            if ev[5] is None:
                raise Fail(f"{name} row at {ev[0]} ns carries no byte count")
            vals.append(ev[5])
        sizes[name] = vals

    for name in ("TransportRead", "InboundChunk"):
        vals = sizes[name]
        print(f"  {name:<16} count {len(vals)}, bytes {sum(vals)}, size {stats(vals, str)}")
    print(f"  {'InboundChunk':<16} ceiling: {ceiling(sizes['InboundChunk'])}")

    drains = sizes["RecvDrain"]
    copied = [v for v in drains if v > 0]
    eof = sum(1 for v in drains if v == 0)
    would_block = sum(1 for v in drains if v < 0)
    print(f"  {'RecvDrain':<16} count {len(drains)}, bytes {sum(copied)}, copied {len(copied)}, "
          f"EOF {eof}, would-block {would_block}, size {stats(copied, str)}")

    # Intervals: pair Begin/End by (name, id) in stream order.
    intervals = {}
    for name in INTERVALS:
        open_begins = {}
        paired = []  # (duration ns, end value)
        unpaired = 0
        for ev in by_name.get(name, []):
            ts, _, _, kind, ident, value, _, _ = ev
            if kind == "Begin":
                if ident in open_begins:
                    unpaired += 1
                open_begins[ident] = ts
            elif kind == "End":
                if ident in open_begins:
                    paired.append((ts - open_begins.pop(ident), value))
                else:
                    unpaired += 1
            else:
                raise Fail(f"{name} row at {ts} ns is a {kind}, expected Begin or End")
        unpaired += len(open_begins)
        intervals[name] = (paired, unpaired)

    dispatch, dispatch_unpaired = intervals["ServiceDispatch"]
    print(f"  {'ServiceDispatch':<16} count {len(dispatch)}, duration ms "
          f"{stats([d for d, _ in dispatch], ms)}, unpaired {dispatch_unpaired}")

    passes, pass_unpaired = intervals["ServicePass"]
    terminal = [d for d, v in passes if v == 1]
    normal = [d for d, v in passes if v != 1]
    print(f"  {'ServicePass':<16} count {len(passes)}, non-terminal {len(normal)}, terminal {len(terminal)}, "
          f"duration ms {stats(normal, ms)}, unpaired {pass_unpaired}")
    if terminal:
        print("    terminal pass durations ms: " + ", ".join(ms(d) for d in terminal))

    # Coalescing ratio and pump-hop latency. The pairing mode is an input, so its line is printed
    # even when there is nothing to pair.
    reads = by_name.get("TransportRead", [])
    chunks = by_name.get("InboundChunk", [])
    if pairing == "per-thread":
        threads = {ev[6] for ev in reads + chunks}
        pairing_line = f"per-thread ({len(threads)} delivery threads)"
    else:
        pairing_line = "global FIFO (byte-sum across threads; for captures before the inbound push-conversion, #45)"
    if not reads:
        print("  coalescing ratio: n/a (no TransportRead events)")
        print(f"  pairing: {pairing_line}")
        print("  pump-hop latency: n/a (no TransportRead events)")
    else:
        ratio = f"{len(reads) / len(chunks):.2f}" if chunks else "n/a"
        print(f"  coalescing ratio: {ratio} ({len(reads)} TransportRead / {len(chunks)} InboundChunk)")
        print(f"  pairing: {pairing_line}")

        ordered = sorted(reads + chunks, key=lambda e: (e[0], e[1]))
        if pairing == "per-thread":
            latencies, without_read, without_chunk, errors, skipped_zero = pair_per_thread(ordered)
            counts = (f"{len(latencies)} pairs, {without_read} chunks without a read, "
                      f"{without_chunk} reads without a chunk, {len(errors)} pairing errors")
        else:
            latencies, reads_per_chunk, errors, skipped_zero = pair_global(ordered)
            if reads_per_chunk:
                dist = ", ".join(f"{n} read{'s' if n != 1 else ''} x{c}" for n, c in sorted(reads_per_chunk.items()))
            else:
                dist = "none"
            print(f"  reads per chunk: {dist}")
            counts = f"{len(latencies)} pairs, {len(errors)} pairing errors"
        print(f"  zero-byte TransportRead skipped: {skipped_zero}")
        print(f"  pump-hop latency ms: {stats(latencies, ms)} ({counts})")
        for err in errors:
            print(f"    pairing error: {err}")

    chunk_total = sum(sizes["InboundChunk"])
    drained = sum(copied)
    print(f"  buffered at end: {chunk_total - drained} bytes (InboundChunk {chunk_total} - RecvDrain {drained})")

    span_ns = events[-1][0] - events[0][0]
    # Active window: the sum of gaps between consecutive subsystem signposts that are <= 1 s,
    # so a burst followed by minutes of keepalives is measured over the burst.
    active_ns = sum(b[0] - a[0] for a, b in zip(events, events[1:]) if b[0] - a[0] <= IDLE_GAP_NS)
    if span_ns > 0:
        print(f"  throughput: {drained / span_ns * NS / 1e6:.3f} MB/s "
              f"(RecvDrain {drained} bytes over {span_ns / NS:.3f} s)")
    else:
        print(f"  throughput: n/a (RecvDrain {drained} bytes, zero wall-clock span)")
    if active_ns > 0:
        print(f"  active throughput: {drained / active_ns * NS / 1e6:.3f} MB/s "
              f"(RecvDrain {drained} bytes over {active_ns / NS:.3f} s active; idle gaps > 1 s excluded)")
    else:
        print(f"  active throughput: n/a (RecvDrain {drained} bytes, zero active time)")


try:
    main()
except Fail as e:
    sys.stdout.flush()
    print(f"error: {e}", file=sys.stderr)
    sys.exit(1)
PY
