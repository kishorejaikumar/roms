# DineFlow | Unit III: relational algebra and tuple relational calculus

Notation: σ select, π project, ρ rename, ⋈ join, ∪ union, ∩ intersection, − difference, 𝒢 grouping with aggregate.
Relations: `restaurant_tables(table_id, table_no, capacity, area, is_active)`, `orders(order_id, customer_id, table_id, status, total_amt, created_at, ...)`, `order_items(order_id, line_no, item_id, quantity, unit_price)`, `menu_items(item_id, name, price, stock_qty, ...)`, `customers(customer_id, full_name, ...)`, `table_reservations(...)`, `payments(payment_id, order_id, method, amount, status, paid_at)`.

## 1. Tables with 4 or more seats in the Family area
π<sub>table_no, capacity</sub>( σ<sub>capacity ≥ 4 ∧ area = 'Family'</sub>( restaurant_tables ) )

```sql
SELECT table_no, capacity FROM restaurant_tables WHERE capacity >= 4 AND area = 'Family';
```

## 2. Customers who have a Paid order AND a live order (intersection)
A = π<sub>customer_id</sub>( σ<sub>status='Paid'</sub>(orders) )  B = π<sub>customer_id</sub>( σ<sub>status ∈ {Placed, Preparing, Served, Billed}</sub>(orders) )
π<sub>full_name</sub>( (A ∩ B) ⋈ customers )

```sql
SELECT full_name FROM customers WHERE customer_id IN
 (SELECT customer_id FROM orders WHERE status='Paid' INTERSECT
  SELECT customer_id FROM orders WHERE status IN ('Placed','Preparing','Served','Billed'));
```

## 3. Dishes that were never ordered (difference)
π<sub>item_id</sub>(menu_items) − π<sub>item_id</sub>(order_items)

```sql
SELECT item_id FROM menu_items EXCEPT SELECT item_id FROM order_items;
```

## 4. Orders with their table number (join + rename)
π<sub>o.order_id, t.table_no, o.status</sub>( ρ<sub>o</sub>(orders) ⋈<sub>o.table_id = t.table_id</sub> ρ<sub>t</sub>(restaurant_tables) )

## 5. Daily revenue grouped by payment method (aggregation)
P = σ<sub>status='Success' ∧ date(paid_at)=d</sub>(payments)
<sub>method</sub> 𝒢 <sub>SUM(amount) → revenue</sub>( P )

```sql
SELECT method, SUM(amount) AS revenue FROM payments WHERE status='Success' AND paid_at::date = :d GROUP BY method;
```

## 6. Orders in a kitchen state (union)
σ<sub>status='Placed'</sub>(orders) ∪ σ<sub>status='Preparing'</sub>(orders)

## 7. Tuple relational calculus
Customers who ordered every Starter-category dish at least once ("division"):

{ c.full_name | c ∈ customers ∧ ∀m ∈ menu_items ( m.category_id = 1 → ∃o ∈ orders ∃l ∈ order_items ( o.customer_id = c.customer_id ∧ l.order_id = o.order_id ∧ l.item_id = m.item_id ) ) }

```sql
SELECT c.full_name FROM customers c WHERE NOT EXISTS (
  SELECT 1 FROM menu_items m WHERE m.category_id = 1 AND NOT EXISTS (
    SELECT 1 FROM orders o JOIN order_items l USING (order_id)
     WHERE o.customer_id = c.customer_id AND l.item_id = m.item_id));
```
