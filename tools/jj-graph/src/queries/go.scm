; Contracts: every named type (interfaces and the structs they describe).
(type_spec name: (type_identifier) @name) @contract
(type_alias name: (type_identifier) @name) @contract

; Implementations: functions, methods, and package-level constants and
; variables.
(function_declaration name: (identifier) @name) @impl
(method_declaration name: (field_identifier) @name) @impl
(source_file (const_declaration (const_spec name: (identifier) @name) @impl))
(source_file (var_declaration (var_spec name: (identifier) @name) @impl))

(import_declaration) @import

; Members: interface methods and struct fields.
(method_elem name: (field_identifier) @member)
(field_declaration name: (field_identifier) @member)
