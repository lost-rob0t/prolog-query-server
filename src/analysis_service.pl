:- module(analysis_service,
          [ analyze_release/3,
            activate_release_strict/2
          ]).

:- use_module(library(error)).
:- use_module(couchdb).
:- use_module(kb_analysis).

analyze_release(KB0, Release0, Analysis) :-
    normalize_text(kb, KB0, KB),
    normalize_text(release, Release0, Release),
    couchdb:find_kb_documents(KB, Release, Documents),
    kb_analysis:analyze_documents(KB, Release, Documents, Analysis).

activate_release_strict(Input, Saved) :-
    must_be(dict, Input),
    input_text(Input, kb, "default", KB),
    required_text(Input, release, Release),
    optional_revision(Input, ExpectedRev),
    kb_mutex(KB, Mutex),
    with_mutex(Mutex,
               ( analyze_release(KB, Release, Analysis),
                 require_valid(Analysis),
                 couchdb:put_kb_manifest(KB, Release, ExpectedRev, CouchReply),
                 Saved = _{kb:KB,
                           active_release:Release,
                           analysis:Analysis,
                           couchdb:CouchReply}
               )).

require_valid(Analysis) :-
    get_dict(valid, Analysis, true),
    !.
require_valid(Analysis) :-
    get_dict(errors, Analysis, Errors),
    throw(error(permission_error(activate, invalid_knowledge_release, Errors), _)).

input_text(Dict, Key, Default, Value) :-
    (get_dict(Key, Dict, Raw) -> normalize_text(Key, Raw, Value) ; Value = Default).

required_text(Dict, Key, Value) :-
    ( get_dict(Key, Dict, Raw)
    -> normalize_text(Key, Raw, Value)
    ; throw(error(existence_error(key, Key), _))
    ).

normalize_text(Key, Raw, Value) :-
    must_be(string, Raw),
    string_length(Raw, Length),
    ( Length > 0, Length =< 128
    -> Value = Raw
    ; throw(error(domain_error(Key, Raw), _))
    ).

optional_revision(Input, Revision) :-
    (   get_dict('_rev', Input, Raw)
    ->  must_be(string, Raw),
        string_length(Raw, Length),
        (Length > 0 -> Revision = Raw ; throw(error(domain_error(document_revision, Raw), _)))
    ;   Revision = null
    ).

kb_mutex(KB, Mutex) :-
    term_hash(KB, Hash),
    format(atom(Mutex), 'prolog-kb-~d', [Hash]).
