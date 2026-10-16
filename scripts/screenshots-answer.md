# Why use a database index?

An index helps the database **find matching rows without scanning the whole table**. Think of it as
a sorted lookup structure alongside your data.

## A practical example

```sql
CREATE INDEX users_email_idx
ON users (email);

SELECT * FROM users
WHERE email = 'demo@example.com';
```

With a B-tree index, this lookup typically takes **O(log n)** work instead of an **O(n)** scan.

## The trade-off

Reads get faster, but indexes use storage and add work to every insert, update, and delete.

**Interview takeaway:** index the queries you actually run, then use `EXPLAIN ANALYZE` to verify the
plan.
