//! The CIM library: parse a CIM document and query, cross-reference, and
//! compare it. This file is the library's public API -- the only entry point
//! anything outside `src/cim/` should import.
//!
//! Everything under `src/cim/` is a self-contained library that happens to
//! live in the cimd repository for now. It holds to three rules, enforced by
//! test_boundary.zig rather than by convention:
//!
//!   1. No imports that escape this directory. The library never reaches into
//!      the CLI's argv parsing, output layer, or file loading.
//!   2. No `std.process.exit`. Failures are returned as errors for the caller
//!      to handle; only an application decides to terminate.
//!   3. No file or network I/O. Callers supply bytes and a `*std.Io.Writer`.
//!
//! A fourth rule runs the other way: application code imports *this file only*,
//! never the library's internals, also enforced by test_boundary.zig. Once the
//! library is its own package Zig enforces that for free -- a package root is
//! the only reachable file -- so holding to it now means the extraction finds no
//! surprises. What it costs today is that anything the application needs must
//! be named here; that is the point, since the alternative is a boundary only
//! the documentation believes in.
//!
//! Those rules are what make the eventual `git mv src/cim <package>/src`
//! mechanical: add a build.zig.zon, repoint consumers from this path to the
//! module name, done.
//! The rest of `src/` -- cli.zig, main.zig, browse.zig, model_set.zig,
//! io/, and validate.zig -- is the application on top and stays behind.
//!
//! Not in scope, deliberately: SHACL validation (validate.zig, shacl/) is a
//! separate concern that may become its own library later.

// ── Documents ─────────────────────────────────────────────────────────────────
//
// CimDocument is the primary parse target and is profile-agnostic: a CIM
// document of any profile (EQ, SSH, TP, SV, DL, DY, GL) parses into one. It is
// not a general RDF/XML parser -- it matches the literal `rdf:` prefix rather
// than resolving namespaces, and indexes zero objects for a document that
// binds RDF to a different prefix. See document.zig.

pub const CimDocument = @import("document.zig").CimDocument;
pub const CimObject = @import("tag_index.zig").CimObject;
pub const Diagnostics = @import("diagnostics.zig").Diagnostics;

/// Object lookup by raw reference value ("_x", "#_x", fragment IRI, path IRI,
/// URN). Owns id normalization and its collision rules -- exact raw match
/// wins, a unique local alias resolves, an ambiguous alias resolves to null.
/// Built by the run that needs it. See reference_index.zig.
pub const ReferenceIndex = @import("reference_index.zig").ReferenceIndex;

/// The same ladder over N borrowed documents, resolving a reference against
/// all of them stage-major. Interns the scope's type names, so a resolved
/// object answers with a type id comparable across documents. See
/// reference_index.zig.
pub const ReferenceScope = @import("reference_index.zig").ReferenceScope;

/// One child element of an object, and the walk that yields them. This is the
/// level a CIM consumer works at; nothing here needs a tag boundary.
pub const Child = @import("tag_index.zig").Child;
pub const ChildIterator = @import("tag_index.zig").ChildIterator;

/// Opt-in index over a document's children: interned names, precomputed kinds
/// and value spans. For consumers that walk the same object many times -- SHACL
/// validation walks it once per shape -- where re-parsing through
/// `object.children()` dominates. Built and owned by the run that wants it, so
/// commands that read each child once do not pay for it. See child_table.zig.
pub const ChildTable = @import("child_table.zig").ChildTable;

/// Raw XML and RDF/XML scanning: tag boundaries, tag types, rdf attribute
/// extraction. The layer under CimDocument, and a module a CIM consumer has no
/// reason to import -- `CimDocument`, `CimObject` and `object.children()`
/// above cover working with a parsed document. It is exported for the callers
/// that scan XML this library does not model: the type-table generator reads
/// RDFS schema files, `profile` reads a FullModel header, `browse` slices
/// source text for display, `validate` counts newlines for line numbers.
///
/// The CIM object layer is deliberately *not* exported alongside it. Its types
/// are named individually above, so `TagBoundary` is reachable only through
/// this module and a consumer that indexes boundaries has to say that it does.
pub const xml_scan = @import("xml_scan.zig");
/// Source positions for error reporting (duplicate-id offsets, line numbers).
pub const diagnostics = @import("diagnostics.zig");
/// CIM class ancestry: `is_a`, `matches_filter` for type filtering.
pub const cim_types = @import("cim_types.zig");
/// mRID normalization: fragment markers, leading underscores, prefix matching.
pub const ids = @import("ids.zig");
/// URI fragment extraction for CIM and RDF references.
pub const uri = @import("uri.zig");
/// Trim-tolerant parsing of CIM property values.
pub const parse = @import("parse.zig");

// ── CGMES profiles ────────────────────────────────────────────────────────────
//
// The profile-specific layer: header classification, and the two overlays that
// patch a primary document.

/// Classify a part from its FullModel header and inspect its exact profile
/// declarations.
pub const profile = @import("cgmes/profile.zig");
/// A supplementary part (TP, SSH) read as patches on a primary document: a
/// `CimDocument` plus an index on the normalized mRID. One type for both
/// profiles; `Overlay.IdPolicy` names the one way they differ.
pub const Overlay = @import("cgmes/overlay.zig").Overlay;
pub const IdPolicy = @import("cgmes/overlay.zig").IdPolicy;
/// Merged read across a document plus its TP/SSH overlays, SSH > TP > document.
pub const CimMergedView = @import("cgmes/overlay.zig").CimMergedView;

// ── References ────────────────────────────────────────────────────────────────
//
// Object lookup (including prefix resolution -- what `cimd get` is built from)
// and the reverse-reference index behind `cimd refs`.

pub const refs = @import("refs.zig");
pub const ReverseRef = refs.ReverseRef;
pub const ReverseRefIndex = refs.ReverseRefIndex;
pub const resolve_object = refs.resolve_object;
pub const resolve_object_normalized = refs.resolve_object_normalized;
pub const collect_target_candidates = refs.collect_target_candidates;
pub const filter_referrers = refs.filter_referrers;

// ── Relations ─────────────────────────────────────────────────────────────
//
// The same references counted rather than followed: one row per distinct
// (source class, property, target) over a whole ReferenceScope. Where `refs`
// answers "what points at this object", this answers "what points at what, and
// how often", without the caller processing individual objects.

pub const relations = @import("relations.zig");
pub const Relation = relations.Relation;
pub const Target = relations.Target;

// ── Diff ──────────────────────────────────────────────────────────────────────
//
// diff_core is the programmatic API: match objects by mRID and get structured
// changes through an emitter. diff and eqdiff are renderers built on it, for
// callers that want the finished report rather than the change set.

/// Change detection: object matching and statement comparison.
pub const diff_core = @import("diff_core.zig");
pub const ChangeSet = diff_core.ChangeSet;
pub const Statement = diff_core.Statement;
/// Report renderers: patch, NDJSON, per-type summary.
pub const diff = @import("diff.zig");
/// IEC 61970-552 difference models.
pub const eqdiff = @import("eqdiff.zig");

// ── Writers ───────────────────────────────────────────────────────────────────

/// Reinterpret an `Allocating` writer's WriteFailed as OutOfMemory. Exposed
/// because callers that buffer library output need the same distinction.
pub const allocating_writer_result = @import("writer.zig").allocating_writer_result;
