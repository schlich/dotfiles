; Contracts: traits and the types they are written against.
(trait_item name: (type_identifier) @name) @contract
(struct_item name: (type_identifier) @name) @contract
(enum_item name: (type_identifier) @name) @contract
(union_item name: (type_identifier) @name) @contract
(type_item name: (type_identifier) @name) @contract

; Implementations: functions and methods, constants, and macros.
(function_item name: (identifier) @name) @impl
(const_item name: (identifier) @name) @impl
(static_item name: (identifier) @name) @impl
(macro_definition name: (identifier) @name) @impl

(use_declaration) @import
(extern_crate_declaration) @import
; A module declared without a body names a file the contracts may live in.
(mod_item !body) @import

; Members: what a contract's users name through it.
(function_signature_item name: (identifier) @member)
(field_declaration name: (field_identifier) @member)
(enum_variant name: (identifier) @member)
(associated_type name: (type_identifier) @member)
