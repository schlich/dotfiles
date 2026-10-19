; JavaScript has no contract syntax: everything is an implementation.
(function_declaration name: (identifier) @name) @impl
(generator_function_declaration name: (identifier) @name) @impl
(class_declaration name: (identifier) @name) @impl
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

; Members: class fields.
(field_definition property: (_) @member)
