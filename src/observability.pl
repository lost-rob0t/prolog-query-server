:- module(observability,
          [ new_request_id/1,
            log_request/5
          ]).

:- use_module(library(gensym)).

new_request_id(RequestId) :-
    gensym(req_, RequestId).

log_request(RequestId, Endpoint, Capability, Outcome, DurationSeconds) :-
    get_time(Now),
    safe_text(RequestId, RequestText),
    safe_text(Endpoint, EndpointText),
    safe_text(Capability, CapabilityText),
    safe_text(Outcome, OutcomeText),
    Log = _{event:"http_request",
            request_id:RequestText,
            endpoint:EndpointText,
            capability:CapabilityText,
            outcome:OutcomeText,
            duration_seconds:DurationSeconds,
            timestamp_unix:Now},
    format(user_error, '~q~n', [Log]).

safe_text(Value, Text) :-
    ( atom(Value) -> atom_string(Value, Text)
    ; string(Value) -> Text = Value
    ; term_string(Value, Text)
    ).
