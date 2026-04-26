UPDATE customer_orders
SET delivery_window_start = created_at + (((customer_order_id % 7) + 1) || ' days')::interval,
    delivery_window_end = created_at + (((customer_order_id % 7) + 1) || ' days')::interval + interval '4 hours',
    delivery_priority = ((customer_order_id % 3) + 1)::smallint
WHERE delivery_window_start IS NULL
   OR delivery_window_end IS NULL
   OR delivery_priority IS NULL;
