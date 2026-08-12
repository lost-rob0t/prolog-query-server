:- module(couchdb,
          [ ensure_storage/0,
            health/1,
            save_document/2,
            put_document/3,
            delete_document/3,
            bulk_documents/2,
            get_document/2,
            find_kb_documents/2,
            find_kb_documents/3,
            get_kb_manifest/2,
            put_kb_manifest/4,
            database_update_seq/1,
            changes_since/3
          ]).

:- use_module(library(http/http_client)).
:- use_module(library(http/http_json)).
:- use_module(library(uri)).
:- use_module(config).

ensure_storage :-
    ensure_database,
    ensure_index.

health(Reply) :-
    config:couchdb_base_url(URL),
    request_options(Options),
    http_get(URL, Reply, [json_object(dict), status_code(Status)|Options]),
    require_status(Status, [200], Reply).

save_document(Document, Reply) :-
    ensure_storage,
    database_url(URL),
    request_options(Options),
    http_post(URL,
              json(Document),
              Reply,
              [json_object(dict), status_code(Status)|Options]),
    require_status(Status, [201, 202], Reply).

put_document(Id, Document0, Reply) :-
    ensure_storage,
    document_url(Id, URL),
    put_dict('_id', Document0, Id, Document),
    request_options(Options),
    http_put(URL,
             json(Document),
             Reply,
             [json_object(dict), status_code(Status)|Options]),
    require_status(Status, [201, 202], Reply).

delete_document(Id, Revision, Reply) :-
    ensure_storage,
    document_url(Id, BaseURL),
    uri_encoded(query_value, Revision, EncodedRevision),
    format(atom(URL), '~w?rev=~w', [BaseURL, EncodedRevision]),
    request_options(Options),
    http_delete(URL,
                Reply,
                [json_object(dict), status_code(Status)|Options]),
    require_status(Status, [200, 202], Reply).

bulk_documents(Documents, Reply) :-
    ensure_storage,
    must_be(list, Documents),
    database_endpoint('_bulk_docs', URL),
    request_options(Options),
    http_post(URL,
              json(_{docs:Documents}),
              Reply,
              [json_object(dict), status_code(Status)|Options]),
    require_status(Status, [201, 202], Reply).

get_document(Id, Document) :-
    ensure_storage,
    document_url(Id, URL),
    request_options(Options),
    http_get(URL,
             Reply,
             [json_object(dict), status_code(Status)|Options]),
    (   Status =:= 200
    ->  Document = Reply
    ;   Status =:= 404
    ->  Document = none
    ;   throw(error(couchdb_error(Status, Reply), _))
    ).

find_kb_documents(KB, Documents) :-
    ensure_storage,
    find_pages(KB, 500, null, [], Reversed),
    reverse(Reversed, Documents).

find_kb_documents(KB, Release, Documents) :-
    find_kb_documents(KB, AllDocuments),
    include(document_in_release(Release), AllDocuments, Documents).

get_kb_manifest(KB, Manifest) :-
    manifest_id(KB, Id),
    get_document(Id, Manifest).

put_kb_manifest(KB, Release, ExpectedRev, Reply) :-
    manifest_id(KB, Id),
    Base = _{type:"prolog_kb_manifest",
             kb:KB,
             active_release:Release},
    (   ExpectedRev == null
    ->  Document = Base
    ;   put_dict('_rev', Base, ExpectedRev, Document)
    ),
    put_document(Id, Document, Reply).

database_update_seq(Sequence) :-
    ensure_storage,
    database_url(URL),
    request_options(Options),
    http_get(URL,
             Reply,
             [json_object(dict), status_code(Status)|Options]),
    require_status(Status, [200], Reply),
    get_dict(update_seq, Reply, Sequence).

changes_since(Since, Changes, LastSequence) :-
    ensure_storage,
    changes_pages(Since, 500, [], Reversed, LastSequence),
    reverse(Reversed, Changes).

changes_pages(Since, Limit, Acc0, Acc, LastSequence) :-
    changes_page(Since, Limit, Page, NextSequence, Pending),
    reverse(Page, ReversedPage),
    append(ReversedPage, Acc0, Acc1),
    length(Page, Count),
    (   Pending =:= 0
    ->  Acc = Acc1,
        LastSequence = NextSequence
    ;   Count =:= 0
    ->  Acc = Acc1,
        LastSequence = NextSequence
    ;   changes_pages(NextSequence, Limit, Acc1, Acc, LastSequence)
    ).

changes_page(Since, Limit, Changes, LastSequence, Pending) :-
    sequence_text(Since, SinceText),
    uri_encoded(query_value, SinceText, EncodedSince),
    database_endpoint('_changes', BaseURL),
    format(atom(URL),
           '~w?since=~w&include_docs=true&style=main_only&limit=~d',
           [BaseURL, EncodedSince, Limit]),
    request_options(Options),
    http_get(URL,
             Reply,
             [json_object(dict), status_code(Status)|Options]),
    require_status(Status, [200], Reply),
    get_dict(results, Reply, Changes),
    get_dict(last_seq, Reply, LastSequence),
    (   get_dict(pending, Reply, Pending0)
    ->  Pending = Pending0
    ;   length(Changes, Count),
        ( Count < Limit -> Pending = 0 ; Pending = 1 )
    ).

sequence_text(Value, Text) :-
    (   string(Value)
    ->  Text = Value
    ;   atom(Value)
    ->  atom_string(Value, Text)
    ;   number(Value)
    ->  number_string(Value, Text)
    ;   term_string(Value, Text)
    ).

document_in_release(Release, Document) :-
    document_release(Document, DocumentRelease),
    DocumentRelease == Release.

document_release(Document, Release) :-
    (   get_dict(release, Document, Release0)
    ->  Release = Release0
    ;   Release = "legacy"
    ).

find_pages(KB, Limit, Bookmark, Acc0, Acc) :-
    find_page(KB, Limit, Bookmark, Page, NextBookmark),
    reverse(Page, PageReversed),
    append(PageReversed, Acc0, Acc1),
    length(Page, Count),
    (   Count < Limit
    ->  Acc = Acc1
    ;   NextBookmark == null
    ->  Acc = Acc1
    ;   find_pages(KB, Limit, NextBookmark, Acc1, Acc)
    ).

find_page(KB, Limit, Bookmark, Documents, NextBookmark) :-
    database_endpoint('_find', URL),
    Selector = _{kb:KB,
                 type:_{'$in':["prolog_fact", "prolog_rule"]}},
    Base = _{selector:Selector, limit:Limit},
    (   Bookmark == null
    ->  Query = Base
    ;   put_dict(bookmark, Base, Bookmark, Query)
    ),
    request_options(Options),
    http_post(URL,
              json(Query),
              Reply,
              [json_object(dict), status_code(Status)|Options]),
    require_status(Status, [200], Reply),
    get_dict(docs, Reply, Documents),
    (   get_dict(bookmark, Reply, NextBookmark0)
    ->  NextBookmark = NextBookmark0
    ;   NextBookmark = null
    ).

ensure_database :-
    database_url(URL),
    request_options(Options),
    http_put(URL,
             json(_{}),
             Reply,
             [json_object(dict), status_code(Status)|Options]),
    require_status(Status, [201, 202, 412], Reply).

ensure_index :-
    database_endpoint('_index', URL),
    Body = _{index:_{fields:["kb", "type"]},
             name:"prolog-kb-type",
             type:"json"},
    request_options(Options),
    http_post(URL,
              json(Body),
              Reply,
              [json_object(dict), status_code(Status)|Options]),
    require_status(Status, [200], Reply).

request_options([timeout(10)|Auth]) :-
    config:couchdb_auth_options(Auth).

database_url(URL) :-
    config:couchdb_base_url(Base),
    config:couchdb_database(Database),
    uri_encoded(path, Database, EncodedDatabase),
    format(atom(URL), '~w/~w', [Base, EncodedDatabase]).

database_endpoint(Path, URL) :-
    database_url(Base),
    format(atom(URL), '~w/~w', [Base, Path]).

document_url(Id, URL) :-
    database_url(Base),
    uri_encoded(path, Id, EncodedId),
    format(atom(URL), '~w/~w', [Base, EncodedId]).

manifest_id(KB, Id) :-
    format(string(Id), 'prolog-kb-manifest:~s', [KB]).

require_status(Status, Allowed, _Reply) :-
    memberchk(Status, Allowed),
    !.
require_status(Status, _Allowed, Reply) :-
    throw(error(couchdb_error(Status, Reply), _)).
