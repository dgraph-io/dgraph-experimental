# Cursor Rules for DQL (Dgraph Query Language)

This directory contains Cursor AI rules that help generate valid and optimized DQL (Dgraph Query Language) queries. These rules guide the AI assistant to understand DQL syntax, patterns, and best practices when working with Dgraph graph databases.

## How to Configure Cursor to Use These Rules

### Option 1: Project Rules (Recommended)

1. **Copy the rules to your project's `.cursor/rules` directory:**
   ```bash
   # From your project root
   mkdir -p .cursor/rules
   cp dql-helper/cursor-rules/*.mdc .cursor/rules/
   ```

2. **Rules will automatically apply** when working on files matching the patterns specified in each rule's metadata (or when explicitly referenced).

### Option 2: Global Rules

1. Open Cursor Settings: `Settings > General > Rules for AI`
2. Copy the content from relevant `.mdc` files into the global rules section
3. These rules will apply across all your projects

### Option 3: Reference Rules Directly

You can reference these rules in your prompts using the `@` syntax:
- `@dql` - References the master DQL rule
- `@dql-simple-query` - References simple query patterns
- `@dql-aggregation` - References aggregation patterns

### Additional Resources

- [Cursor Rules Documentation](https://docs.cursor.com/en/context/rules) - Official guide on configuring and using Cursor rules
- [Dgraph DQL Documentation](https://dgraph.io/docs/query-language/) - Official DQL language reference
- [Dgraph Query Examples](https://dgraph.io/docs/query-language/query-examples/) - Real-world query examples

## What These Rules Do

These rules provide specialized guidance for generating DQL queries, mutations, and understanding Dgraph's graph database patterns. Each rule focuses on a specific aspect of DQL:

### Core Rules

#### `dql.mdc` - Master Rule
The main entry point that orchestrates query generation. It:
- Identifies the appropriate query pattern based on user input
- Routes to specialized rules for specific query types
- Ensures queries are parameterized with meaningful names
- Validates query syntax before responding
- **When to use**: General query requests or when unsure which pattern to use

#### `dql-language.mdc` - Language Structure & Validation
Provides fundamental understanding of DQL syntax:
- Query structure (query blocks, var blocks, parameters)
- Parameter syntax and types (`int`, `float`, `bool`, `string`)
- Variable usage and validation rules
- Critical rules for avoiding unused variables
- **When to use**: Automatically referenced by other rules for syntax validation

### Query Pattern Rules

#### `dql-simple-query.mdc` - Basic Query Patterns
Covers fundamental query patterns for retrieving entities:
- **Basic node retrieval** by unique identifier
- **Multiple nodes** with filtering using `anyofterms`, `allofterms`, `has`
- **Advanced filtering** with `@filter` and logical operators
- **Nested relationships** (1st, 2nd, and deeper degree connections)
- **Common root functions**: `eq()`, `anyofterms()`, `allofterms()`, `has()`, `type()`
- **When to use**: Standard entity retrieval, filtering, and relationship traversal queries

#### `dql-aggregation.mdc` - Aggregation Operations
Handles mathematical operations and statistics:
- **Counting**: Entities, relationships, filtered subsets
- **Statistical functions**: `sum()`, `avg()`, `min()`, `max()`
- **Hierarchical aggregations**: Parent-child rollups
- **Time-based aggregations**: Grouping by date ranges
- **Ranking**: Top-K queries with `orderdesc`/`orderasc`
- **Conditional aggregations**: Complex filtering with aggregations
- **When to use**: Analytics, reporting, statistics, counting operations

#### `dql-nth-degree-count.mdc` - Nth-Degree Counting
Specialized for counting unique related nodes across multiple relationship levels:
- Counting distinct nodes at various degrees of separation
- Avoiding duplicate counts in complex graph traversals
- **When to use**: "How many unique X are connected to Y through Z" type queries

#### `dql-generic-nth-degree-recommendation.mdc` - Recommendation Queries
Generates queries for finding related nodes based on relationship counting:
- Finding entities with the most connections
- Recommendation algorithms (e.g., "users who liked X also liked Y")
- Relationship-based similarity queries
- **When to use**: Recommendation systems, similarity searches, "find related" queries

### Mutation Rules

#### `dql-upsert.mdc` - Mutations & Upserts
Handles data modifications:
- **Conditional upserts**: Create if not exists, update if exists
- Prevents duplicate data using `@upsert` directive
- Mutation patterns for safe data writing
- **When to use**: Creating or updating nodes, preventing duplicates

## Rule Selection Guide

The AI automatically selects the appropriate rule based on your query intent:

```
User Query Type → Rule Applied
─────────────────────────────────
"Find entities matching X" → dql-simple-query
"Count how many..." → dql-aggregation or dql-nth-degree-count
"Find related/recommended..." → dql-generic-nth-degree-recommendation
"Create or update X" → dql-upsert
General query → dql (master rule, routes automatically)
```

## Best Practices

These rules enforce several best practices:

1. **Parameterization**: All queries use meaningful parameter names with default values
2. **Comments**: Queries include explanatory comments for complex logic
3. **Validation**: Syntax validation is performed before returning queries
4. **Performance**: Filters are applied early, avoiding unnecessary data retrieval
5. **Variable Usage**: Unused variables are avoided to prevent errors
6. **Type Safety**: Appropriate data types are used for parameters and predicates

## Example Usage

When you ask Cursor AI:

> "Find all movies released after 2020 directed by directors who have won awards"

The AI will:
1. Use `dql.mdc` to identify this as a filtering query with relationships
2. Reference `dql-simple-query.mdc` for the pattern
3. Generate a parameterized DQL query with proper filtering and nested relationships
4. Validate the syntax before returning

## Contributing

To add or modify rules:
1. Create or edit `.mdc` files in this directory
2. Follow the MDC format with frontmatter metadata
3. Include clear descriptions and examples
4. Test with various query scenarios
5. Update this README to document new rules



