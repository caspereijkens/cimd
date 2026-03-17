# cimd
cimd is a high-performance tool for working with CGMES (Common Grid Model Exchange Standard) data.

## Pipeline

cimd is a pipeline of the following stages:

1. **Check if file is zipped**
   - If no: read full file into memory
   - If yes: unzip all files into memory
   - Warning: (extracted) filesize must be < 4GB

2. **Index the file one-by-one**
   - Find all locations of `<` and `>` in the file (leveraging SIMD for turbo)
   - Make a list of all tags (CIM objects AND property tags) that holds the bare minimum: where does each tag start (location in the text) and where does each tag stop
   - For each tag with an `rdf:ID` (these are CIM objects), we collect metadata:
     - Extract the object's ID (e.g., `_SS1`) and its position
     - Find the closing tag index for this object
     - Extract the object's type (e.g., `Substation`)
     - Build two indices:
       - `id_to_index`: HashMap from ID → position in objects array
       - `type_index`: HashMap from type name → list of object array indices

     This metadata forms the **CimModel** struct - a pure index with zero content copying. The CimModel is the foundation where each feature of cimd will build on. It is like a big index of where what is in the text, but without storing any content. The content stays in the original XML, and only when the content is really needed, we look them up via the index that was created. 

This system design is what should make CIMD very fast.

## Visual Example
Here's what's actually stored in the `CimModel` when parsing a simple XML file:

Original XML:
```xml
<cim:Substation rdf:ID="_SS1">
  <cim:IdentifiedObject.name>North Station</cim:IdentifiedObject.name>
</cim:Substation>
```

CimModel structure:
```
CimModel
├── xml: "<cim:Substation rdf:ID=\"_SS1\">..." → [pointer to original buffer]
│
├── boundaries: []TagBoundary
│   ├── [0] { start: 0, end: 33 }      → <cim:Substation rdf:ID="_SS1">
│   ├── [1] { start: 34, end: 63 }     → <cim:IdentifiedObject.name>
│   ├── [2] { start: 64, end: 99 }     → </cim:IdentifiedObject.name>
│   └── [3] { start: 100, end: 116 }   → </cim:Substation>
│
├── objects: []CimObject
│   └── [0] CimObject
│       ├── xml → [pointer to same buffer]
│       ├── boundaries → [pointer to same boundaries array]
│       ├── object_tag_idx: 0          → points to boundaries[0]
│       ├── closing_tag_idx: 3         → points to boundaries[3]
│       ├── id: "_SS1"                 → slice of xml[29..33]
│       └── type_name: "Substation"    → slice of xml[5..15]
│
├── id_to_index: HashMap<string, u32>
│   └── "_SS1" → 0                     → points to objects[0]
│
└── type_index: HashMap<string, []u32>
    └── "Substation" → [0]             → [objects[0]]
```

And this should hold all the information to perform the cimd operations.


## Conversion to JIIDM
One of the main challenges in the JIIDM conversion is that some of the voltage levels are merged. This merge creates we have *stubs* and *representatives*: *stubs* are merged into *representatives*. So, each equipment that is referencing a CIM voltage level, has to be rerouted to its representative voltage level. In the majority of cases, the referenced voltage level *is* the representative, but in some minority of cases the referenced voltage level is a stub.  
