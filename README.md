# cimd
cimd is a high-performance tool for working with CGMES (Common Grid Model Exchange Standard) data.

## Pipeline
cimd is a pipeline of the following stages:
1. Check if file is zipped.
    a. If no, read full file into memory 
    b. If yes, unzip all files into memory.
   Warning: (extracted) filesize must be < 4GB.
2. Index the file one-by-one.
    a. Find all locations of '<' and '>' in the file (leveraging SIMD for turbo).
    b. Make a list of all tags (CIM objects AND property tags) that holds the bare minimum: where does each tag start (location in the text) and where does each tag stop. 
    c. For each tag with an rdf:ID (these are CIM objects), we collect metadata:
       - Extract the object's ID (e.g., "_SS1") and its position
       - Find the closing tag index for this object
       - Extract the object's type (e.g., "Substation")
       - Build two indices:
         * id_to_index: HashMap from ID → position in objects array
         * type_index: HashMap from type name → list of object array indices

       This metadata forms the CimModel struct - a pure index with zero content copying.
   The metadata collected in step 2c is what makes up the CimModel struct. The CimModel struct is the fundament where each feature of cimd will build on. It is like a big index of where what is in the text, but without storing any content. The content stays in the original xml, and only when the content is really needed, we look them up via the index that is created. 

This system design is what should make CIMD very fast.
