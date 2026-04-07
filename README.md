# cimd
cimd is a high-performance tool for working with CGMES (Common Grid Model Exchange Standard) data. See https://cimd.eu for more information.

## Performance

![CGMES EQ → JIIDM conversion benchmark: cimd vs pypowsybl](docs/benchmark.svg)

*Converting a real-world 4.8 MB zipped EQ file to JIIDM.*

*Measured on Apple M4 Pro · both tools processing the same EQ + EQBD input · median of 6 warm runs.*

<!-- FEATURES_START -->
## Features
```
$ cimd eq --help

Usage: cimd eq <subcommand> <file> [options]

Operate on a CGMES EQ (Equipment) profile.

Subcommands:
  convert    Convert EQ profile to JIIDM JSON
  browse     Interactively browse equipment objects by following references
  get        Fetch a single object by mRID (JSON output)
  types      List all CIM types present in the file

Use 'cimd eq <subcommand> --help' for more information.
```

### Convert
```
$ cimd eq convert --help

Usage: cimd eq convert <file> [options]

Convert a CGMES EQ profile to JIIDM JSON format.
Output is written to stdout unless --output is given.

Arguments:
  <file>            EQ profile (XML or ZIP)

Options:
  --eqbd <file>     EQBD boundary profile (XML or ZIP)
  --output <file>   Write output to file instead of stdout

Examples:
  cimd eq convert data/eq.zip
  cimd eq convert data/eq.zip --eqbd eqbd.zip
  cimd eq convert data/eq.zip --output network.json
```

### Browse
```
$ cimd eq browse --help

Usage: cimd eq browse <file> <mrid> [options]

Interactively browse equipment objects by following rdf:resource references.

Arguments:
  <file>    EQ profile (XML or ZIP)
  <mrid>    mRID of the object to start browsing from

Options:
  --eqbd <file>     EQBD boundary profile (XML or ZIP)

Examples:
  cimd eq browse data/eq.zip _be60a3cf-fed6-d11c-c15f-42ac6cc4e221
```

### Get
```
$ cimd eq get --help

Usage: cimd eq get <file> <mrid> [options]

Fetch a single CIM object by mRID and print it as JSON.
Exits 0 on success, 1 if the mRID is not found.

Arguments:
  <file>    EQ profile (XML or ZIP)
  <mrid>    mRID of the object to fetch

Options:
  --eqbd <file>     EQBD boundary profile (XML or ZIP)
  --type <type>     Filter by CIM type (e.g. PowerTransformer)

Examples:
  cimd eq get data/eq.zip _be60a3cf-fed6-d11c-c15f-42ac6cc4e221
  cimd eq get data/eq.zip _be60a3cf-fed6-d11c-c15f-42ac6cc4e221 --type PowerTransformer
```

### Types
```
$ cimd eq types --help

Usage: cimd eq types <file> [options]

List all CIM types present in the EQ profile with object counts.

Arguments:
  <file>            EQ profile (XML or ZIP)

Options:
  --eqbd <file>     EQBD boundary profile (XML or ZIP)
  --json            Output as JSON array of {type, count} objects

Examples:
  cimd eq types data/eq.zip
  cimd eq types data/eq.zip --json
```
<!-- FEATURES_END -->
