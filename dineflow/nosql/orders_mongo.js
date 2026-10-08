// =====================================================================
// DineFlow | UNIT V : NoSQL document model in MongoDB (comparison with PostgreSQL)
// Run:  mongosh "mongodb://localhost:27017/dineflow" nosql/orders_mongo.js
// (Atlas free tier works too: mongosh "<your connection string>" nosql/orders_mongo.js)
// =====================================================================
db.orders.drop();
db.menu_items.drop();

// One ORDER = one document. Items, customer name, table and payments are EMBEDDED,
// so a whole bill is read with one lookup and no join. The price is copied in (a snapshot),
// exactly like order_items.unit_price in PostgreSQL.
db.menu_items.insertMany([
  { _id: 1,  name: "Paneer Tikka",               category: "Starters",       price: 240, veg: true,  stock: 120 },
  { _id: 4,  name: "Butter Chicken",             category: "Mains",          price: 340, veg: false, stock: 120 },
  { _id: 8,  name: "Hyderabadi Chicken Biryani", category: "Biryani & Rice", price: 320, veg: false, stock: 150 },
  { _id: 11, name: "Butter Naan",                category: "Breads",         price: 55,  veg: true,  stock: 300 },
  { _id: 18, name: "Gulab Jamun",                category: "Desserts",       price: 95,  veg: true,  stock: 100 }
]);

db.orders.insertMany([
  { order_no: 1001, customer: { id: 1, name: "Asha Rao" }, table: "T01", type: "Dine-in", status: "Paid",
    created_at: new ISODate("2026-10-01T13:10:00+05:30"),
    items: [ { item_id: 1, name: "Paneer Tikka", qty: 2, unit_price: 240, note: "Extra mint chutney" },
             { item_id: 4, name: "Butter Chicken", qty: 1, unit_price: 340 },
             { item_id: 11, name: "Butter Naan", qty: 4, unit_price: 55 } ],
    subtotal: 1040, discount: 0, gst: 52, total: 1092,
    payments: [ { method: "UPI", amount: 1092, upi_ref: "asha@okhdfc" } ],
    reviews: [ { item_id: 1, rating: 5, comment: "Perfectly charred" } ] },
  { order_no: 1002, customer: { id: 2, name: "Vikram Shah" }, table: "T04", type: "Dine-in", status: "Paid",
    created_at: new ISODate("2026-10-01T20:15:00+05:30"),
    items: [ { item_id: 8, name: "Hyderabadi Chicken Biryani", qty: 2, unit_price: 320 },
             { item_id: 18, name: "Gulab Jamun", qty: 2, unit_price: 95 } ],
    subtotal: 830, discount: 83, gst: 37.35, total: 784.35, coupon: "WELCOME10",
    payments: [ { method: "Card", amount: 400, card_last4: "4242" }, { method: "Cash", amount: 384.35 } ],   // split bill
    // Flexible field only some documents have: no ALTER TABLE needed
    feedback_tags: ["great-biryani", "slow-dessert"] },
  { order_no: 1003, customer: { id: 3, name: "Meera Iyer" }, table: null, type: "Takeaway", status: "Preparing",
    created_at: new Date(),
    items: [ { item_id: 11, name: "Butter Naan", qty: 6, unit_price: 55 } ],
    subtotal: 330, discount: 0, gst: 16.5, total: 346.5, payments: [] }
]);

db.orders.createIndex({ status: 1, created_at: -1 });          // like idx_orders_live
db.orders.createIndex({ "customer.id": 1, created_at: -1 });   // like idx_orders_customer_recent
db.orders.createIndex({ "items.item_id": 1 });                 // multikey index on an embedded array

print("--- 1. one bill with no join (PostgreSQL needs orders + order_items + payments)");
printjson(db.orders.findOne({ order_no: 1002 }));

print("--- 2. kitchen queue (status Placed/Preparing), oldest first");
printjson(db.orders.find({ status: { $in: ["Placed", "Preparing"] } }, { order_no: 1, table: 1, "items.name": 1, "items.qty": 1 }).sort({ created_at: 1 }).toArray());

print("--- 3. top dishes by units (aggregation pipeline = GROUP BY over unnested order_items)");
printjson(db.orders.aggregate([
  { $match: { status: "Paid" } },
  { $unwind: "$items" },
  { $group: { _id: "$items.name", units: { $sum: "$items.qty" }, revenue: { $sum: { $multiply: ["$items.qty", "$items.unit_price"] } } } },
  { $sort: { units: -1 } }, { $limit: 5 }
]).toArray());

print("--- 4. revenue by payment method (split payments unwound)");
printjson(db.orders.aggregate([
  { $match: { status: "Paid" } }, { $unwind: "$payments" },
  { $group: { _id: "$payments.method", total: { $sum: "$payments.amount" } } }, { $sort: { total: -1 } }
]).toArray());

print("--- 5. orders that contain a given dish (uses the multikey index)");
printjson(db.orders.find({ "items.item_id": 18 }, { order_no: 1, total: 1 }).toArray());
printjson(db.orders.find({ "items.item_id": 18 }).explain("executionStats").executionStats.totalDocsExamined);

print("--- 6. add a new field to ONE document without touching the others (schema-less)");
db.orders.updateOne({ order_no: 1001 }, { $set: { feedback_tags: ["tasty", "quick"] } });

// ---------------------------------------------------------------------------------
// SQL vs MongoDB for this project (write this table in the report)
//  Concern                  | PostgreSQL (used)                           | MongoDB (this file)
//  Bill read                | 3 tables joined                             | 1 document, no join
//  Stock + order atomically | one ACID tx, row locks, CHECK stock >= 0    | multi-doc transactions exist but are
//                           |                                             | awkward; stock in another collection
//  Integrity                | FK, CHECK, triggers, exclusion constraint   | validation rules only; no FK
//  Changing a menu price    | one row; old bills keep unit_price          | embedded copies are never updated (good)
//  Ad-hoc reports           | SQL, views, window functions                | aggregation pipeline (more verbose)
//  Flexible attributes      | JSONB column when needed                    | native
//  Decision: money, stock and status rules need ACID + constraints, so the system of record is PostgreSQL;
//  documents suit read-heavy "order history" or feedback data that is copied out of PostgreSQL.
// ---------------------------------------------------------------------------------
