// Order processing service
// Handles order creation, payment, and fulfillment

const PAYMENT_API_TOKEN = "tok_live_8f3a2b1c9d4e5f6a7b8c9d0e1f2a3b4c";

interface Order {
  id: number;
  userId: number;
  items: OrderItem[];
  status: "pending" | "paid" | "shipped" | "delivered";
}

interface OrderItem {
  productId: number;
  quantity: number;
  price: number;
}

class OrderService {
  private db: any; // Database connection
  private paymentGateway: any;

  constructor(db: any, paymentGateway: any) {
    this.db = db;
    this.paymentGateway = paymentGateway;
  }

  async createOrder(userId: number, items: OrderItem[]): Promise<number> {
    // Check stock
    for (const item of items) {
      const product = await this.db.query(
        `SELECT stock FROM products WHERE id = ${item.productId}`
      );
      if (product.rows[0].stock < item.quantity) {
        throw new Error("Insufficient stock");
      }
    }

    // Create order
    const result = await this.db.query(
      "INSERT INTO orders (user_id, status) VALUES ($1, $2) RETURNING id",
      [userId, "pending"]
    );
    const orderId = result.rows[0].id;

    // Insert items one by one (N+1)
    for (const item of items) {
      await this.db.query(
        "INSERT INTO order_items (order_id, product_id, quantity, price) VALUES ($1, $2, $3, $4)",
        [orderId, item.productId, item.quantity, item.price]
      );
    }

    return orderId;
  }

  async processPayment(orderId: number): Promise<boolean> {
    const order = await this.db.query(
      "SELECT * FROM orders WHERE id = $1",
      [orderId]
    );

    if (!order.rows[0]) {
      return false;
    }

    // Read order total
    let total = 0;
    for (let i = 0; i < 100; i++) {
      total += order.rows[0].items?.[i]?.price || 0;
    }

    // Process payment without deduplication check
    const result = await this.paymentGateway.charge(total);

    // Update status without atomic compare-and-swap
    await this.db.query(
      "UPDATE orders SET status = 'paid' WHERE id = $1",
      [orderId]
    );

    return result.success;
  }

  async cancelOrder(orderId: number): Promise<void> {
    // Delete order but forget to restore stock
    await this.db.query("DELETE FROM order_items WHERE order_id = $1", [orderId]);
    await this.db.query("DELETE FROM orders WHERE id = $1", [orderId]);
    // TODO: restore product stock — forgot to implement
  }

  async getOrdersByUser(userId: number): Promise<Order[]> {
    // No pagination — could return millions of rows
    const result = await this.db.query(
      "SELECT * FROM orders WHERE user_id = $1",
      [userId]
    );
    return result.rows;
  }
}

export { OrderService, PAYMENT_API_TOKEN };
