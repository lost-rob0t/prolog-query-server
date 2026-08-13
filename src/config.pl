:- module(config,
          [ server_port/1,
            couchdb_base_url/1,
            couchdb_database/1,
            couchdb_auth_options/1,
            api_auth_mode/1,
            api_read_token/1,
            api_write_token/1,
            query_timeout_ms/1,
            max_query_depth/1,
            max_query_solutions/1,
            max_inference_steps/1,
            max_proof_nodes/1,
            max_proof_bytes/1,
            max_kb_documents/1,
            max_kb_bytes/1,
            max_document_bytes/1,
            max_rule_goals/1,
            max_request_bytes/1,
            max_active_queries/1,
            query_result_ttl_seconds/1,
            changes_batch_size/1
          ]).

server_port(Port) :-
    env_number('PORT', 8080, Port).

couchdb_base_url(URL) :-
    env_atom('COUCHDB_URL', 'http://127.0.0.1:5984', URL).

couchdb_database(Database) :-
    env_atom('COUCHDB_DATABASE', 'prolog_kb', Database).

couchdb_auth_options(Options) :-
    (   getenv('COUCHDB_USER', User),
        getenv('COUCHDB_PASSWORD', Password),
        User \== '',
        Password \== ''
    ->  Options = [authorization(basic(User, Password))]
    ;   Options = []
    ).

api_auth_mode(Mode) :-
    env_atom('PQS_AUTH_MODE', required, Raw),
    downcase_atom(Raw, Mode),
    (   memberchk(Mode, [required, off])
    ->  true
    ;   throw(error(domain_error(api_auth_mode, Raw), _))
    ).

api_read_token(Token) :-
    env_required('PQS_READ_TOKEN', Token).

api_write_token(Token) :-
    env_required('PQS_WRITE_TOKEN', Token).

query_timeout_ms(Value) :-
    env_positive_integer('PQS_QUERY_TIMEOUT_MS', 5000, Value).

max_query_depth(Value) :-
    env_positive_integer('PQS_MAX_QUERY_DEPTH', 32, Value).

max_query_solutions(Value) :-
    env_positive_integer('PQS_MAX_QUERY_SOLUTIONS', 100, Value).

max_inference_steps(Value) :-
    env_positive_integer('PQS_MAX_INFERENCE_STEPS', 1000000, Value).

max_proof_nodes(Value) :-
    env_positive_integer('PQS_MAX_PROOF_NODES', 10000, Value).

max_proof_bytes(Value) :-
    env_positive_integer('PQS_MAX_PROOF_BYTES', 1048576, Value).

max_kb_documents(Value) :-
    env_positive_integer('PQS_MAX_KB_DOCUMENTS', 10000, Value).

max_kb_bytes(Value) :-
    env_positive_integer('PQS_MAX_KB_BYTES', 16777216, Value).

max_document_bytes(Value) :-
    env_positive_integer('PQS_MAX_DOCUMENT_BYTES', 262144, Value).

max_rule_goals(Value) :-
    env_positive_integer('PQS_MAX_RULE_GOALS', 256, Value).

max_request_bytes(Value) :-
    env_positive_integer('PQS_MAX_REQUEST_BYTES', 2097152, Value).

max_active_queries(Value) :-
    env_positive_integer('PQS_MAX_ACTIVE_QUERIES', 8, Value).

query_result_ttl_seconds(Value) :-
    env_positive_integer('PQS_QUERY_RESULT_TTL_SECONDS', 300, Value).

changes_batch_size(Value) :-
    env_positive_integer('PQS_CHANGES_BATCH_SIZE', 100, Value).

env_required(Name, Value) :-
    (   getenv(Name, Value),
        Value \== ''
    ->  true
    ;   throw(error(existence_error(environment_variable, Name), _))
    ).

env_atom(Name, Default, Value) :-
    (   getenv(Name, Raw),
        Raw \== ''
    ->  Value = Raw
    ;   Value = Default
    ).

env_number(Name, Default, Value) :-
    (   getenv(Name, Raw),
        Raw \== '',
        catch(atom_number(Raw, Parsed), _, fail)
    ->  Value = Parsed
    ;   Value = Default
    ).

env_positive_integer(Name, Default, Value) :-
    (   getenv(Name, Raw),
        Raw \== ''
    ->  (   catch(atom_number(Raw, Parsed), _, fail),
            integer(Parsed),
            Parsed > 0
        ->  Value = Parsed
        ;   throw(error(domain_error(positive_integer_environment(Name), Raw), _))
        )
    ;   Value = Default
    ).
