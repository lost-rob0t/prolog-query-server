:- module(api_errors,
          [ error_response/3,
            error_payload/2
          ]).

error_response(Error, Status, Payload) :-
    error_mapping(Error, Status, Payload),
    !.
error_response(_Error, 400, _{error:"bad_request"}).

error_payload(Error, Payload) :-
    error_response(Error, _Status, Payload).

error_mapping(error(pqs_query_resource(query_timeout, QueryId, Limit), _),
              504,
              _{error:"query_timeout", query_id:QueryId, limit:Limit}).
error_mapping(error(pqs_query_resource(inference_budget, QueryId, Limit), _),
              422,
              _{error:"inference_budget_exhausted", query_id:QueryId, limit:Limit}).
error_mapping(error(pqs_query_resource(proof_limit, QueryId, Limit), _),
              422,
              _{error:"proof_limit_exhausted", query_id:QueryId, limit:Limit}).
error_mapping(error(pqs_query_cancelled(QueryId), _),
              409,
              _{error:"query_cancelled", query_id:QueryId}).
error_mapping(error(pqs_query_not_found(QueryId), _),
              404,
              _{error:"query_not_found", query_id:QueryId}).
error_mapping(error(pqs_query_not_cancellable(QueryId, State), _),
              409,
              _{error:"query_not_cancellable", query_id:QueryId, state:State}).
error_mapping(error(pqs_resource_limit(active_queries, Limit), _),
              503,
              _{error:"query_capacity_exhausted", limit:Limit}).
error_mapping(error(pqs_resource_limit(request_size, Limit), _),
              413,
              _{error:"payload_too_large", limit:Limit}).
error_mapping(error(pqs_resource_limit(document_size, Limit), _),
              413,
              _{error:"knowledge_document_too_large", limit:Limit}).
error_mapping(error(pqs_resource_limit(kb_document_count, Limit), _),
              422,
              _{error:"kb_document_limit_exceeded", limit:Limit}).
error_mapping(error(pqs_resource_limit(kb_size, Limit), _),
              422,
              _{error:"kb_size_limit_exceeded", limit:Limit}).
error_mapping(error(pqs_resource_limit(rule_goal_count, Limit), _),
              422,
              _{error:"rule_goal_limit_exceeded", limit:Limit}).
error_mapping(error(permission_error(access, api_authentication, _), _),
              401,
              _{error:"authentication_required"}).
error_mapping(error(permission_error(access, api_capability, _), _),
              403,
              _{error:"insufficient_capability"}).
error_mapping(error(existence_error(environment_variable, Name), _),
              503,
              _{error:"server_configuration_error", setting:Name}).
error_mapping(error(permission_error(activate, invalid_knowledge_release, _), _),
              409,
              _{error:"invalid_knowledge_release"}).
error_mapping(error(couchdb_error(409, _), _),
              409,
              _{error:"couchdb_conflict"}).
error_mapping(error(couchdb_error(_, _), _),
              502,
              _{error:"couchdb_error"}).
error_mapping(error(existence_error(knowledge_document, _), _),
              404,
              _{error:"knowledge_document_not_found"}).
error_mapping(error(permission_error(load, conflicted_knowledge_document, _), _),
              409,
              _{error:"conflicted_knowledge_document"}).
error_mapping(error(permission_error(modify, _, _), _),
              409,
              _{error:"knowledge_modification_conflict"}).
error_mapping(error(existence_error(knowledge_base, _), _),
              409,
              _{error:"knowledge_base_not_loaded"}).
