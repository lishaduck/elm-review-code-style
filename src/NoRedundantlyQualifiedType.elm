module NoRedundantlyQualifiedType exposing (rule)

{-|

@docs rule

-}

import Elm.Syntax.Declaration exposing (Declaration(..))
import Elm.Syntax.Exposing as Exposing
import Elm.Syntax.Expression as Expression exposing (Function, LetDeclaration(..))
import Elm.Syntax.Import exposing (Import)
import Elm.Syntax.ModuleName exposing (ModuleName)
import Elm.Syntax.Node as Node exposing (Node(..))
import Elm.Syntax.TypeAnnotation exposing (RecordField, TypeAnnotation(..))
import Review.Fix as Fix exposing (Fix)
import Review.ModuleNameLookupTable as ModuleNameLookupTable exposing (ModuleNameLookupTable)
import Review.Rule as Rule exposing (Rule)
import Set exposing (Set)


{-| Reports when a type is qualified by a module (alias) of the same name.

🔧 Running with `--fix` will automatically remove most of the reported errors.

    config =
        [ NoRedundantlyQualifiedType.rule
        ]

There is a convention in Elm to center modules around a type, and to name the module after the type. Usually, such a module is imported like this:

    import Inventory.Fruit as Fruit exposing (Fruit)

That allows you to refer to values like `Fruit.apple` and to the type `Fruit`. When inferring types, you might end up with `Fruit.Fruit`. It can be considered a bit silly to say the same word twice like that. It's clear where the `Fruit` type comes from anyway. This rule simplifies to just `Fruit`.


## Fail

    import Set

    directions : Set.Set String
    directions =
        Set.fromList [ "north", "south", "east", "west" ]


## Success

    import Set exposing (Set)

    directions : Set String
    directions =
        Set.fromList [ "north", "south", "east", "west" ]


## When (not) to enable this rule

This rule resolves a minor style issue, and may not be worth enforcing depending on how strongly you feel about this issue.


## Try it out

You can try this rule out by running the following command:

```bash
elm-review --template jfmengels/elm-review-code-style/example --rules NoRedundantlyQualifiedType
```

-}
rule : Rule
rule =
    Rule.newProjectRuleSchema "NoRedundantlyQualifiedType" initialContext
        |> Rule.withModuleVisitor moduleVisitor
        -- TODO Add dependencies visitor
        |> Rule.withModuleContextUsingContextCreator
            { fromProjectToModule = fromProjectToModule
            , fromModuleToProject = fromModuleToProject
            , foldProjectContexts = foldProjectContexts
            }
        |> Rule.withContextFromImportedModules
        |> Rule.providesFixesForProjectRule
        |> Rule.fromProjectRuleSchema


moduleVisitor : Rule.ModuleRuleSchema schemaState ModuleContext -> Rule.ModuleRuleSchema { schemaState | hasAtLeastOneVisitor : () } ModuleContext
moduleVisitor schema =
    schema
        |> Rule.withDeclarationEnterVisitor (\node context -> ( declarationVisitor node context, context ))
        |> Rule.withLetDeclarationEnterVisitor (\_ node context -> ( letDeclarationEnterVisitor node context, context ))


type alias ProjectContext =
    { exposesSelfNamedType : Set ModuleName
    }


type alias ModuleContext =
    { lookupTable : ModuleNameLookupTable
    , imports : List (Node Import)
    , typesDefinedInModule : Set String
    , exposesSelfNamedType : Set ModuleName
    }


initialContext : ProjectContext
initialContext =
    { exposesSelfNamedType = Set.empty
    }


fromProjectToModule : Rule.ContextCreator ProjectContext ModuleContext
fromProjectToModule =
    Rule.initContextCreator
        (\lookupTable ast projectContext ->
            { lookupTable = lookupTable
            , imports = ast.imports
            , typesDefinedInModule = collectTypesDefinedInModule ast.declarations
            , exposesSelfNamedType = projectContext.exposesSelfNamedType
            }
        )
        |> Rule.withModuleNameLookupTable
        |> Rule.withFullAst


fromModuleToProject : Rule.ContextCreator ModuleContext ProjectContext
fromModuleToProject =
    Rule.initContextCreator
        (\moduleName moduleContext ->
            let
                lastSegment : String
                lastSegment =
                    case List.reverse moduleName of
                        [] ->
                            "unknown"

                        typeName :: _ ->
                            typeName
            in
            { exposesSelfNamedType =
                -- TODO Only look at contents if exposing (..)
                -- Otherwise look at exposing clause
                if Set.member lastSegment moduleContext.typesDefinedInModule then
                    Set.singleton moduleName

                else
                    Set.empty
            }
        )
        |> Rule.withModuleName


foldProjectContexts : ProjectContext -> ProjectContext -> ProjectContext
foldProjectContexts newContext previousContext =
    { exposesSelfNamedType = Set.union newContext.exposesSelfNamedType previousContext.exposesSelfNamedType
    }


collectTypesDefinedInModule : List (Node Declaration) -> Set String
collectTypesDefinedInModule =
    List.filterMap
        (\node ->
            case Node.value node of
                FunctionDeclaration _ ->
                    Nothing

                AliasDeclaration typeAlias ->
                    Just (Node.value typeAlias.name)

                CustomTypeDeclaration type_ ->
                    Just (Node.value type_.name)

                PortDeclaration _ ->
                    Nothing

                InfixDeclaration _ ->
                    Nothing

                Destructuring _ _ ->
                    Nothing
        )
        >> Set.fromList


declarationVisitor : Node Declaration -> ModuleContext -> List (Rule.Error {})
declarationVisitor node context =
    case Node.value node of
        FunctionDeclaration function ->
            doFunction context function

        AliasDeclaration typeAlias ->
            doTypeAnnotation context typeAlias.typeAnnotation

        CustomTypeDeclaration type_ ->
            type_.constructors
                |> List.concatMap
                    (Node.value
                        >> .arguments
                        >> List.concatMap (doTypeAnnotation context)
                    )

        PortDeclaration signature ->
            doTypeAnnotation context signature.typeAnnotation

        InfixDeclaration _ ->
            []

        Destructuring _ _ ->
            []


letDeclarationEnterVisitor : Node Expression.LetDeclaration -> ModuleContext -> List (Rule.Error {})
letDeclarationEnterVisitor letDeclaration context =
    case Node.value letDeclaration of
        LetFunction function ->
            doFunction context function

        LetDestructuring _ _ ->
            []


doFunction : ModuleContext -> Function -> List (Rule.Error {})
doFunction context function =
    case function.signature of
        Just (Node _ signature) ->
            doTypeAnnotation context signature.typeAnnotation

        Nothing ->
            []


doTypeAnnotation : ModuleContext -> Node TypeAnnotation -> List (Rule.Error {})
doTypeAnnotation context typeAnnotation =
    case Node.value typeAnnotation of
        GenericType _ ->
            []

        Typed constructor arguments ->
            doConstructor context constructor ++ (arguments |> List.concatMap (doTypeAnnotation context))

        Unit ->
            []

        Tupled arguments ->
            arguments |> List.concatMap (doTypeAnnotation context)

        Record recordDefinition ->
            doRecordDefinition recordDefinition context

        GenericRecord _ (Node _ recordDefinition) ->
            doRecordDefinition recordDefinition context

        FunctionTypeAnnotation left right ->
            doTypeAnnotation context left ++ doTypeAnnotation context right


doRecordDefinition : List (Node RecordField) -> ModuleContext -> List (Rule.Error {})
doRecordDefinition recordDefinition context =
    recordDefinition
        |> List.concatMap
            (\(Node _ ( _, typeAnnotation )) ->
                doTypeAnnotation context typeAnnotation
            )


doConstructor : ModuleContext -> Node ( ModuleName, String ) -> List (Rule.Error {})
doConstructor context constructor =
    case constructor of
        Node range ( [ qualifier ], name ) ->
            if qualifier /= name || Set.member name context.typesDefinedInModule then
                []

            else
                case ModuleNameLookupTable.moduleNameFor context.lookupTable constructor of
                    Just moduleName ->
                        let
                            ( matchingImports, otherImports ) =
                                context.imports
                                    |> partition (\import_ -> Node.value (Node.value import_).moduleName == moduleName)
                        in
                        if exposes name otherImports then
                            []

                        else
                            [ Rule.errorWithFix
                                { message = "This type can be simplified to just `" ++ name ++ "`."
                                , details = [ "It can be considered a bit silly to say the same word twice like in `" ++ name ++ "." ++ name ++ "`. This rule simplifies to just `" ++ name ++ "`. This follows the convention of centering modules around a type." ]
                                }
                                range
                                (Fix.removeRange
                                    { start = range.start
                                    , end =
                                        { row = range.start.row

                                        -- Add 1 to the column to remove the dot.
                                        , column = range.start.column + String.length name + 1
                                        }
                                    }
                                    :: importFix name matchingImports
                                )
                            ]

                    -- Should not happen.
                    Nothing ->
                        []

        _ ->
            []


exposes : String -> List (Node Import) -> Bool
exposes name =
    List.any
        (\importNode ->
            case (Node.value importNode).exposingList of
                Just (Node _ exposing_) ->
                    case exposing_ of
                        Exposing.All _ ->
                            True

                        Exposing.Explicit nodes ->
                            nodes
                                |> List.any
                                    (\topLevelExposeNode ->
                                        case Node.value topLevelExposeNode of
                                            Exposing.FunctionExpose _ ->
                                                False

                                            Exposing.InfixExpose _ ->
                                                False

                                            Exposing.TypeOrAliasExpose exposedName ->
                                                exposedName == name

                                            Exposing.TypeExpose exposedType ->
                                                exposedType.name == name
                                    )

                _ ->
                    False
        )


firstExposed : List (Node Import) -> Maybe (Node Exposing.TopLevelExpose)
firstExposed =
    List.filterMap
        (\importNode ->
            case (Node.value importNode).exposingList of
                Just (Node _ (Exposing.Explicit (first :: _))) ->
                    Just first

                _ ->
                    Nothing
        )
        >> List.head


importFix : String -> List (Node Import) -> List Fix
importFix name matchingImports =
    if exposes name matchingImports then
        []

    else
        case firstExposed matchingImports of
            Just existingExposing ->
                [ Fix.insertAt (Node.range existingExposing).start (name ++ ", ") ]

            Nothing ->
                case matchingImports of
                    -- If no matching imports, assume it is part of the default imports.
                    [] ->
                        []

                    firstImport :: _ ->
                        [ Fix.insertAt (Node.range firstImport).end (" exposing (" ++ name ++ ")") ]


partition : (a -> Bool) -> List a -> ( List a, List a )
partition predicate list =
    List.foldr
        (\element ( trueList, falseList ) ->
            if predicate element then
                ( element :: trueList, falseList )

            else
                ( trueList, element :: falseList )
        )
        ( [], [] )
        list
