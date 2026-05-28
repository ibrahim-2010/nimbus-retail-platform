# OrderCreated Event Flow

Shows the asynchronous path from a customer placing an order to the confirmation notification being dispatched.

```mermaid
sequenceDiagram
    autonumber
    actor Customer
    participant order-service
    participant RDS as RDS (PostgreSQL)
    participant Redis as ElastiCache (Redis)
    participant cart-service
    participant Kafka as Kafka<br/>(orders.created)
    participant notification-service

    Customer->>+order-service: POST /orders
    order-service->>+cart-service: GET /cart/{userId}
    cart-service->>+Redis: GET cart:{userId}
    Redis-->>-cart-service: cart items
    cart-service-->>-order-service: cart contents

    order-service->>+RDS: INSERT INTO orders
    RDS-->>-order-service: order_id

    order-service->>+Kafka: Produce OrderCreated<br/>{ order_id, user_id, items, total }
    Kafka-->>-order-service: ack (offset committed)

    order-service-->>-Customer: 201 Created { order_id }

    Note over Kafka,notification-service: Asynchronous — decoupled from the HTTP response

    Kafka->>+notification-service: Consume OrderCreated event
    notification-service->>notification-service: Build confirmation payload
    notification-service-->>-Customer: Email / SMS confirmation
```

## Notes

- Steps 1–8 are synchronous and part of the HTTP request/response cycle. The customer receives a `201` as soon as the order is persisted and the Kafka produce is acknowledged.
- The notification dispatch (steps 9–11) is fully asynchronous. A Kafka produce failure does **not** fail the order — it is retried by Kafka's producer retry logic.
- `cart-service` is called synchronously to validate cart contents before the order is written to RDS.
- Consumer group for `notification-service` on this topic: `notification-service-group`.
- Topic: `orders.created` is auto-created on first produce (`auto.create.topics.enable: true`). Replication factor: 3. Partition count: Kafka default (1) unless a `KafkaTopic` resource is added to define it explicitly.
