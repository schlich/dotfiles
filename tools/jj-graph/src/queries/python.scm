; Contracts: protocols, abstract bases, and schemas (typed records, enums,
; data classes, models), and type aliases.
(class_definition
  name: (identifier) @name
  superclasses: (argument_list) @bases
  (#match? @bases "(Protocol|ABC|ABCMeta|TypedDict|NamedTuple|Enum|IntEnum|StrEnum|Flag|IntFlag|BaseModel)")) @contract

(decorated_definition
  (decorator) @decorator
  definition: (class_definition name: (identifier) @name)
  (#match? @decorator "(dataclass|attr\\.s|attrs\\.define|attrs\\.frozen)")) @contract

(type_alias_statement left: (_) @name) @contract

(module
  (expression_statement
    (assignment
      left: (identifier) @name
      type: (type) @annotation
      (#match? @annotation "TypeAlias")) @contract))

; Implementations: classes, functions, methods, and module constants.
(class_definition name: (identifier) @name) @impl
(function_definition name: (identifier) @name) @impl
(module (expression_statement (assignment left: (identifier) @name) @impl))

(import_statement) @import
(import_from_statement) @import
(future_import_statement) @import

; Members: class attributes.
(class_definition body: (block (expression_statement (assignment left: (identifier) @member))))
