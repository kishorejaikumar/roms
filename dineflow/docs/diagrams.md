# DineFlow diagrams (Mermaid)

Paste each block into https://mermaid.live (or a GitHub .md preview) and export as PNG for the report.

## Figure 4.2: ER diagram

```mermaid
erDiagram
  CUSTOMERS ||--o{ ADDRESSES : has
  CUSTOMERS ||--o{ TABLE_RESERVATIONS : books
  CUSTOMERS ||--o{ ORDERS : places
  CUSTOMERS ||--o{ REVIEWS : writes
  CUSTOMERS ||--o{ COUPON_USAGE : redeems
  RESTAURANT_TABLES ||--o{ TABLE_RESERVATIONS : reserved_as
  RESTAURANT_TABLES ||--o{ ORDERS : serves
  TABLE_RESERVATIONS |o--o{ ORDERS : seated_for
  CATEGORIES ||--o{ MENU_ITEMS : groups
  MENU_ITEMS ||--o{ ORDER_ITEMS : appears_in
  ORDERS ||--|{ ORDER_ITEMS : contains
  ORDERS ||--o{ PAYMENTS : paid_by
  ORDERS ||--o{ ORDER_SPLITS : split_into
  PAYMENTS |o--o{ ORDER_SPLITS : settles
  COUPONS ||--o{ ORDERS : discounts
  COUPONS ||--o{ COUPON_USAGE : tracked_by
  ORDERS ||--o| COUPON_USAGE : uses
  ORDER_ITEMS ||--o| REVIEWS : rated_in
  STATUS_FLOW }o--o{ ORDERS : governs

  CUSTOMERS { int customer_id PK
    string full_name
    string email UK
    string phone
    string password_hash }
  STAFF { int staff_id PK
    string email UK
    enum role "kitchen or admin"
    string password_hash }
  ADDRESSES { int address_id PK
    int customer_id FK
    string pincode }
  RESTAURANT_TABLES { int table_id PK
    string table_no UK
    int capacity }
  TABLE_RESERVATIONS { int reservation_id PK
    int customer_id FK
    int table_id FK
    timestamptz start_time
    timestamptz end_time
    enum status }
  CATEGORIES { int category_id PK
    string name UK }
  MENU_ITEMS { int item_id PK
    int category_id FK
    decimal price
    int stock_qty
    bool is_sold_out }
  ORDERS { int order_id PK
    bigint order_no UK
    int customer_id FK
    int table_id FK
    int coupon_id FK
    enum status
    decimal subtotal
    decimal discount_amt
    decimal tax_amt
    decimal total_amt }
  ORDER_ITEMS { int order_id PK
    int line_no PK
    int item_id FK
    int quantity
    decimal unit_price }
  PAYMENTS { int payment_id PK
    int order_id FK
    enum method
    decimal amount
    enum status }
  COUPONS { int coupon_id PK
    string code UK
    enum discount_type
    int max_total_uses
    int used_count }
  COUPON_USAGE { int usage_id PK
    int coupon_id FK
    int customer_id FK
    int order_id FK }
  ORDER_SPLITS { int order_id PK
    int split_no PK
    string payer_name
    decimal amount
    int payment_id FK }
  REVIEWS { int review_id PK
    int order_id FK
    int item_id FK
    int rating }
  STATUS_FLOW { enum from_status PK
    enum to_status PK
    array allowed_roles }
  AUDIT_LOG { bigint audit_id PK
    string table_name
    int record_id
    jsonb old_data
    jsonb new_data }
  DAILY_SETTLEMENT { date settle_date PK
    decimal net_sales
    decimal tax_total }
```

`staff`, `audit_log` and `daily_settlement` have no foreign keys by design: staff log in separately from customers, the audit log must survive deletions, and settlement rows are summaries.

## Figure 4.1: Architecture

```mermaid
flowchart LR
  subgraph Browser
    C[Customer pages<br/>menu, cart, reservation, my orders]
    K[Kitchen display]
    A[Admin dashboard]
  end
  subgraph Render["Render: Node.js + Express"]
    AU[Auth: signed token + role check]
    RT[Routes: menu, orders, payments,<br/>reservations, coupons, reviews, reports]
  end
  subgraph Supabase["Supabase: PostgreSQL"]
    T[(Tables + constraints)]
    R[Triggers, functions,<br/>procedures, views]
    X[Indexes, materialised view]
  end
  M[(MongoDB script<br/>NoSQL comparison)]
  C & K & A -->|HTTPS JSON| AU --> RT -->|parameterised SQL via pg| R --> T
  T --- X
  T -.->|export for comparison| M
```

## Figure 4.3: Order status flow (from `status_flow`)

```mermaid
stateDiagram-v2
  [*] --> Placed
  Placed --> Preparing: kitchen / admin
  Preparing --> Served: kitchen / admin
  Served --> Billed: admin / system
  Billed --> Paid: admin / system
  Placed --> Cancelled: customer / admin
  Preparing --> Cancelled: customer / admin
  Paid --> [*]
  Cancelled --> [*]
```
