from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    target = Path(path)
    text = target.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {old!r}")
    target.write_text(text.replace(old, new, 1))


# CouchDB reads must carry conflict metadata through both snapshots and _changes.
replace_once(
    "src/couchdb.pl",
    """    document_url(Id, URL),\n    request_options(Options),\n    http_get(URL,\n""",
    """    document_url(Id, BaseURL),\n    format(atom(URL), '~w?conflicts=true', [BaseURL]),\n    request_options(Options),\n    http_get(URL,\n""",
)
replace_once(
    "src/couchdb.pl",
    """           '~w?since=~w&include_docs=true&style=main_only&limit=~d',\n""",
    """           '~w?since=~w&include_docs=true&conflicts=true&style=main_only&limit=~d',\n""",
)
replace_once(
    "src/couchdb.pl",
    """    Base = _{selector:Selector, limit:Limit},\n""",
    """    Base = _{selector:Selector, limit:Limit, conflicts:true},\n""",
)

# Export conflict inventory functions.
replace_once(
    "src/kb_service.pl",
    """            knowledge_documents/3,\n            knowledge_document/2,\n""",
    """            knowledge_documents/3,\n            knowledge_conflicts/2,\n            knowledge_conflicts/3,\n            knowledge_document/2,\n""",
)

# Add metadata-only conflict inventory after knowledge listing.
replace_once(
    "src/kb_service.pl",
    """knowledge_documents(KB, Release0, Documents) :-\n    normalize_release_value(Release0, Release),\n    couchdb:find_kb_documents(KB, Release, Documents).\n\nknowledge_document(Id0, Document) :-\n""",
    """knowledge_documents(KB, Release0, Documents) :-\n    normalize_release_value(Release0, Release),\n    couchdb:find_kb_documents(KB, Release, Documents).\n\nknowledge_conflicts(KB, Conflicts) :-\n    couchdb:find_kb_documents(KB, Documents),\n    conflict_inventory(KB, Documents, Conflicts).\n\nknowledge_conflicts(KB, Release0, Conflicts) :-\n    normalize_release_value(Release0, Release),\n    couchdb:find_kb_documents(KB, Release, Documents),\n    conflict_inventory(KB, Documents, Conflicts).\n\nconflict_inventory(KB, Documents, Conflicts) :-\n    findall(Conflict,\n            ( member(Document, Documents),\n              knowledge_conflict_metadata(Document, Conflict)\n            ),\n            DocumentConflicts),\n    couchdb:get_kb_manifest(KB, Manifest),\n    (   Manifest == none\n    ->  ManifestConflicts = []\n    ;   manifest_conflict_metadata(Manifest, ManifestConflicts)\n    ),\n    append(ManifestConflicts, DocumentConflicts, Conflicts).\n\nknowledge_conflict_metadata(Document, Conflict) :-\n    conflict_revisions(Document, Revisions),\n    required(Document, '_id', Id),\n    required(Document, '_rev', WinningRevision),\n    required(Document, type, Type),\n    knowledge_kind(Type, Kind),\n    document_release(Document, Release),\n    Conflict = _{id:Id,\n                 kind:Kind,\n                 release:Release,\n                 winning_rev:WinningRevision,\n                 conflicts:Revisions}.\n\nmanifest_conflict_metadata(Manifest, [Conflict]) :-\n    conflict_revisions(Manifest, Revisions),\n    !,\n    required(Manifest, '_id', Id),\n    required(Manifest, '_rev', WinningRevision),\n    optional(Manifest, active_release, null, ActiveRelease),\n    Conflict = _{id:Id,\n                 kind:\"manifest\",\n                 release:ActiveRelease,\n                 winning_rev:WinningRevision,\n                 conflicts:Revisions}.\nmanifest_conflict_metadata(_Manifest, []).\n\nknowledge_kind(\"prolog_fact\", \"fact\").\nknowledge_kind(\"prolog_rule\", \"rule\").\n\nknowledge_document(Id0, Document) :-\n""",
)

# Reject conflicts on any fact/rule entering a full snapshot.
replace_once(
    "src/kb_service.pl",
    """    couchdb:find_kb_documents(KB, Release, Documents),\n    runtime_key(KB, Release, RuntimeKB),\n""",
    """    couchdb:find_kb_documents(KB, Release, Documents),\n    ensure_documents_conflict_free(Documents),\n    runtime_key(KB, Release, RuntimeKB),\n""",
)

# Reject conflicts arriving through incremental changes before upsert.
replace_once(
    "src/kb_service.pl",
    """        document_matches_runtime(Document, KB, Release)\n    ->  expert_system:upsert_document(RuntimeKB, Document, _Outcome),\n""",
    """        document_matches_runtime(Document, KB, Release)\n    ->  ensure_document_conflict_free(Document),\n        expert_system:upsert_document(RuntimeKB, Document, _Outcome),\n""",
)

# Reject a conflicted active-release manifest before choosing the release.
replace_once(
    "src/kb_service.pl",
    """    ;   required(Manifest0, active_release, Release0),\n        normalize_release_value(Release0, Release),\n""",
    """    ;   ensure_document_conflict_free(Manifest0),\n        required(Manifest0, active_release, Release0),\n        normalize_release_value(Release0, Release),\n""",
)

# Add conflict helpers before document_release/2.
replace_once(
    "src/kb_service.pl",
    """document_release(Document, Release) :-\n""",
    """ensure_documents_conflict_free(Documents) :-\n    maplist(ensure_document_conflict_free, Documents).\n\nensure_document_conflict_free(Document) :-\n    (   conflict_revisions(Document, Revisions)\n    ->  required(Document, '_id', Id),\n        throw(error(permission_error(load,\n                                     conflicted_knowledge_document,\n                                     _{id:Id, conflicts:Revisions}),\n                    _))\n    ;   true\n    ).\n\nconflict_revisions(Document, Revisions) :-\n    get_dict('_conflicts', Document, Revisions),\n    is_list(Revisions),\n    Revisions \\== [].\n\ndocument_release(Document, Release) :-\n""",
)

# API: expose metadata-only conflict inventory and map fail-closed loads to HTTP 409.
replace_once(
    "src/api.pl",
    """:- http_handler(root('v1/analyze'), analyze_handler, [method(post)]).\n""",
    """:- http_handler(root('v1/analyze'), analyze_handler, [method(post)]).\n:- http_handler(root('v1/conflicts'), conflicts_handler, [method(get)]).\n""",
)
replace_once(
    "src/api.pl",
    """analyze_handler(Request) :-\n""",
    """conflicts_handler(Request) :-\n    observed_secured_call(Request, conflicts, read, 200,\n                          ( http_parameters(Request,\n                                            [ kb(KBAtom, [default(default)]),\n                                              release(ReleaseAtom, [default('')])\n                                            ]),\n                            atom_string(KBAtom, KB),\n                            conflicts_for_release(KB, ReleaseAtom, Conflicts),\n                            length(Conflicts, Count),\n                            reply_json_dict(_{kb:KB,\n                                              count:Count,\n                                              conflicts:Conflicts})\n                          )).\n\nconflicts_for_release(KB, '', Conflicts) :-\n    !,\n    kb_service:knowledge_conflicts(KB, Conflicts).\nconflicts_for_release(KB, ReleaseAtom, Conflicts) :-\n    atom_string(ReleaseAtom, Release),\n    kb_service:knowledge_conflicts(KB, Release, Conflicts).\n\nanalyze_handler(Request) :-\n""",
)
replace_once(
    "src/api.pl",
    """error_status(error(permission_error(modify, _, _), _), 409) :- !.\n""",
    """error_status(error(permission_error(load, conflicted_knowledge_document, _), _), 409) :- !.\nerror_status(error(permission_error(modify, _, _), _), 409) :- !.\n""",
)
