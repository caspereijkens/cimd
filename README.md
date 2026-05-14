![LOGO](docs/cimd-icon-square-transparent.svg)

# cimd
cimd is a **C**ommand line **I**nterface for grid **M**odel **D**ata. It is a high-performance tool for working with CGMES (Common Grid Model Exchange Standard) data. See https://cimd.eu for more information.

## Performance
### Benchmark on synthetic data
![CGMES EQ → JIIDM conversion benchmark](docs/benchmark_classic.svg)
*Conversion to JIIDM on synthetic data for eq sizes up to 1GB (unzipped).*

### Comparison on real data
![CGMES EQ → JIIDM conversion benchmark: cimd vs pypowsybl](scripts/benchmark/output/benchmark.svg)

*End-to-end CGMES → in-memory pypowsybl `Network` on a real-world Dutch transmission model (EQ + EQBD, ~5MB zipped). The `cimd` bar measures `cimd convert` (ReleaseFast) writing JIIDM to disk plus `pypowsybl.network.load` reading it back; the `pypowsybl` bar measures `pypowsybl.network.load_from_binary_buffers` on the same CGMES inputs.*

*Median of 10 runs after a discarded warm-up. Measured on Apple M4 Pro. Reproduce with `scripts/benchmark/main.py`.*

<!-- FEATURES_START -->
## Features
```
$ cimd --help

Usage: cimd <command> [options]

A high-performance CGMES file parser and analysis tool.

Commands:
  convert    Convert an EQ profile to JIIDM JSON
  browse     Interactively browse CIM objects (EQ/EQBD/TP/SSH merged view)
  get        Fetch a single object or list by type from any CIM file
  types      List CIM types present in a CIM file
  diff       Semantic diff between two EQ profiles
  topology   Generate TopologicalNodes from EQ (+SSH) — TP-equivalent output
  version    Print version information

Use 'cimd <command> --help' for more information about a command.
```

### Convert
```
$ cimd convert --help

Usage: cimd convert <file> [options]

Convert a CGMES EQ profile to JIIDM JSON format.
Output is written to stdout unless --output is given.

Arguments:
  <file>                  EQ profile (XML or ZIP)

Options:
  -b, --boundary <file>   EQBD boundary profile (XML or ZIP)
  -t, --topology <file>   TP topology profile (XML or ZIP)
  -s, --ssh <file>        SSH steady-state hypothesis profile (XML or ZIP)
  -o, --output <file>     Write output to file instead of stdout
      --bus-branch        Emit bus-branch JIIDM (one bus per TopologicalNode).
                          Requires --topology. Default is node-breaker even
                          when TP is given (matches pypowsybl).

Examples:
  cimd convert data/eq.zip
  cimd convert data/eq.zip -b eqbd.zip
  cimd convert data/eq.zip -b eqbd.zip -s ssh.zip
  cimd convert data/eq.zip -o network.json
  cimd convert data/eq.zip -t tp.zip --bus-branch
```

### Browse
```
$ cimd browse --help

Usage: cimd browse <file> <mrid> [options]

Interactively browse CIM objects by following rdf:resource references.
When --topology or --ssh is passed, patches from those profiles are shown
inline alongside the primary object, and new objects from TP (e.g.
TopologicalNodes) become navigable by mRID.

<mrid> may be a prefix of a full mRID; the leading underscore is optional.
The prefix is matched against EQ objects and, when --topology is given,
TP-added objects (e.g. TopologicalNodes). When a prefix matches more than
one object, browse opens a picker menu — flat list when few candidates,
grouped by type when many.

Arguments:
  <file>    Primary CIM file (typically EQ; XML or ZIP)
  <mrid>    Full mRID or a prefix of one

Options:
  -b, --boundary <file>       EQBD boundary profile (XML or ZIP)
  -t, --topology <file>       TP topology profile (XML or ZIP)
  -s, --ssh <file>            SSH steady-state hypothesis profile (XML or ZIP)

Examples:
  cimd browse data/eq.zip _be60a3cf-fed6-d11c-c15f-42ac6cc4e221
  cimd browse data/eq.zip be60a3cf                # prefix; underscore optional
  cimd browse data/eq.zip _abc -t tp.zip -s ssh.zip
```

### Get
```
$ cimd get --help

Usage: cimd get <file> [<mrid>] [options]

Fetch a CIM object by mRID (or a prefix of one), or list all objects of a
given type. Works on any CGMES file (EQ, EQBD, TP, SSH, ...).
At least one of <mrid> or --type must be provided.
Exits 0 on success, 1 if no object is found.

Prefix lookup:
  <mrid> may be any prefix of a full mRID; the leading underscore is
  optional, so "_be60" and "be60" are equivalent. When a prefix matches
  multiple objects, cimd prints the candidates and exits without selecting
  one — or, if the match list is large, prints a per-type breakdown
  instead. With --json, an envelope `{"prefix","total","matches","types"}`
  is emitted regardless of match count. Pass --type to narrow ambiguous
  prefixes to a single type.

JSON errors:
  With --json, the not-found / wrong-type paths emit a structured error
  on stdout and exit 1 instead of printing to stderr:
    {"error":"not_found", "prefix":...}
    {"error":"type_mismatch", "prefix":..., "id":..., "actual_type":..., "requested_type":...}
    {"error":"none_of_type", "prefix":..., "total":..., "requested_type":...}

Arguments:
  <file>    CGMES file (XML or ZIP)
  <mrid>    Full mRID or a unique prefix (optional if --type is given)

Options:
  -t, --type <type>          Filter by CIM type (e.g. PowerTransformer)
                             Without <mrid>: list all objects of this type
                             With <mrid>: verify the object is of this type,
                             or narrow an ambiguous prefix to one of this type
  -f, --fields <f1,f2,...>   Properties to include in list output (list mode only)
                             Text default: IdentifiedObject.name
                             JSON default: full object (all properties + references)
  -c, --count                Print only the count of matching objects (list mode only)
  -j, --json                 Output as JSON. In list mode, each element is
                             {"id","type","properties":{...},"references":{...}}
                             unless --fields narrows the projection.

Examples:
  cimd get data/eq.zip _be60a3cf-fed6-d11c-c15f-42ac6cc4e221
  cimd get data/eq.zip be60a3cf                          # prefix; underscore optional
  cimd get data/eq.zip _be60a3cf-fed6-d11c-c15f-42ac6cc4e221 -j
  cimd get data/eq.zip _be60a3cf-fed6-d11c-c15f-42ac6cc4e221 -t PowerTransformer
  cimd get data/eq.zip be60 -t PowerTransformer          # narrow ambiguous prefix
  cimd get data/eq.zip -t PowerTransformer -j
  cimd get data/eq.zip -t PowerTransformer -c
  cimd get data/eq.zip -t VoltageLevel -f IdentifiedObject.name,VoltageLevel.nominalVoltage
  cimd get data/tp.zip -t TopologicalNode -c
```

### Types
```
$ cimd types --help

Usage: cimd types <file> [options]

List all CIM types present in a CGMES file with object counts.
Works on any CGMES file (EQ, EQBD, TP, SSH, ...).

Arguments:
  <file>                  CGMES file (XML or ZIP)

Options:
  -j, --json              Output as JSON array of {{type, count}} objects

Examples:
  cimd types data/eq.zip
  cimd types data/tp.zip -j
```

### Diff
```
$ cimd diff --help

Usage: cimd diff <file1> <file2> [options]

Compare two CGMES EQ profiles semantically. Objects are matched by mRID
across both files; properties are compared field-by-field. XML attribute
order and whitespace differences are ignored.

Exit codes:
  0  files are identical (no differences found)
  1  differences found
  2  usage error

Arguments:
  <file1>    First EQ profile (XML or ZIP)
  <file2>    Second EQ profile (XML or ZIP)

Options:
  -b, --boundary <file>   EQBD boundary profile (applied to both models)
  -i, --mrid <id>         Diff a single object by mRID
  -t, --type <name>       Restrict diff to a specific CIM type
                          With --mrid: verify the object is of this type
  -s, --summary           Print only per-type counts (added/removed/changed)
  -j, --json              Output as NDJSON (one object per change)

Examples:
  cimd diff eq_v1.zip eq_v2.zip
  cimd diff eq_v1.zip eq_v2.zip -i _abc123
  cimd diff eq_v1.zip eq_v2.zip -i _abc123 -t PowerTransformer
  cimd diff eq_v1.zip eq_v2.zip -t PowerTransformer
  cimd diff eq_v1.zip eq_v2.zip -j | jq .
  cimd diff eq_v1.zip eq_v2.zip -s
```

### Topology
```
$ cimd topology --help

Usage: cimd topology <file> [options]

Generate TopologicalNodes from an EQ profile (and optional SSH). Each TN is
a connected component of ConnectivityNodes joined by *closed* switches —
equivalent to a CGMES TP profile's terminal→TopologicalNode mapping.
Output is JSON on stdout.

Without --ssh, all switches are treated as closed (electrical-equivalence
snapshot ignoring switch state).

Arguments:
  <file>                  EQ profile (XML or ZIP)

Options:
  -b, --boundary <file>   EQBD boundary profile (XML or ZIP)
  -s, --ssh <file>        SSH steady-state hypothesis profile (XML or ZIP)
  -o, --output <file>     Write output to file instead of stdout

Examples:
  cimd topology data/eq.zip -s ssh.zip
  cimd topology data/eq.zip -b eqbd.zip -s ssh.zip -o tn.json
```
<!-- FEATURES_END -->
