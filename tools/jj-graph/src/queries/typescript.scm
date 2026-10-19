; Contracts: interfaces, type aliases, enums, abstract classes, and
; function signatures.
(interface_declaration name: (type_identifier) @name) @contract
(type_alias_declaration name: (type_identifier) @name) @contract
(enum_declaration name: (identifier) @name) @contract
(abstract_class_declaration name: (type_identifier) @name) @contract
(function_signature name: (identifier) @name) @contract

; Implementations: functions, classes, methods, and module-level bindings.
(function_declaration name: (identifier) @name) @impl
(generator_function_declaration name: (identifier) @name) @impl
(class_declaration name: (type_identifier) @name) @impl
(method_definition name: (_) @name) @impl
(program (lexical_declaration (variable_declarator name: (identifier) @name) @impl))
(program (variable_declaration (variable_declarator name: (identifier) @name) @impl))
(export_statement (lexical_declaration (variable_declarator name: (identifier) @name) @impl))
(export_statement (variable_declaration (variable_declarator name: (identifier) @name) @impl))

; An export clause puts the names it exports in the module's interface, so
; adding or dropping one changes what importers can name.
(export_specifier alias: (_) @name) @impl
(export_specifier name: (_) @name !alias) @impl

(import_statement) @import

; Members: what an interface, type, or enum's users name through it.
(method_signature name: (_) @member)
(property_signature name: (_) @member)
(abstract_method_signature name: (_) @member)
(enum_body (property_identifier) @member)
(enum_assignment name: (_) @member)
(public_field_definition name: (_) @member)
