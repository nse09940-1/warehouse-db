#include <drogon/drogon.h>
#include <drogon/orm/DbClient.h>

#include <cstdlib>
#include <exception>
#include <functional>
#include <memory>
#include <string>

using drogon::HttpRequestPtr;
using drogon::HttpResponse;
using drogon::HttpResponsePtr;
using drogon::HttpStatusCode;
using drogon::app;
using drogon::orm::DrogonDbException;
using drogon::orm::Result;

namespace
{
std::string envOrDefault(const char *name, const std::string &fallback)
{
    const char *value = std::getenv(name);
    if (value == nullptr || std::string(value).empty())
    {
        return fallback;
    }
    return value;
}

int envIntOrDefault(const char *name, int fallback)
{
    const char *value = std::getenv(name);
    if (value == nullptr)
    {
        return fallback;
    }
    try
    {
        return std::stoi(value);
    }
    catch (const std::exception &)
    {
        return fallback;
    }
}

bool envBoolOrDefault(const char *name, bool fallback)
{
    const char *value = std::getenv(name);
    if (value == nullptr)
    {
        return fallback;
    }

    const std::string raw(value);
    return raw == "1" || raw == "true" || raw == "TRUE" || raw == "yes" || raw == "on";
}

HttpResponsePtr jsonResponse(const Json::Value &body,
                             HttpStatusCode status = drogon::k200OK)
{
    auto response = HttpResponse::newHttpJsonResponse(body);
    response->setStatusCode(status);
    response->addHeader("Access-Control-Allow-Origin", "*");
    response->addHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    response->addHeader("Access-Control-Allow-Headers", "Content-Type");
    return response;
}

HttpResponsePtr optionsResponse()
{
    auto response = HttpResponse::newHttpResponse();
    response->setStatusCode(drogon::k204NoContent);
    response->addHeader("Access-Control-Allow-Origin", "*");
    response->addHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    response->addHeader("Access-Control-Allow-Headers", "Content-Type");
    return response;
}

HttpResponsePtr errorResponse(const std::string &message,
                              HttpStatusCode status = drogon::k500InternalServerError)
{
    Json::Value body;
    body["error"] = message;
    return jsonResponse(body, status);
}

std::string queryParamOrDefault(const HttpRequestPtr &request,
                                const std::string &name,
                                const std::string &fallback)
{
    const auto value = request->getParameter(name);
    return value.empty() ? fallback : value;
}

std::string normalizedStatus(const HttpRequestPtr &request)
{
    const auto json = request->getJsonObject();
    if (json && json->isMember("status") && (*json)["status"].isString())
    {
        const auto status = (*json)["status"].asString();
        if (status == "new" || status == "confirmed" || status == "picking" ||
            status == "shipped" || status == "delivered" || status == "cancelled")
        {
            return status;
        }
    }
    return "confirmed";
}

Json::Value orderRowToJson(const drogon::orm::Row &row)
{
    Json::Value order;
    order["order_id"] = Json::Int64(row["customer_order_id"].as<long long>());
    order["customer_id"] = Json::Int64(row["customer_id"].as<long long>());
    order["customer_name"] = row["full_name"].as<std::string>();
    order["delivery_address"] = row["delivery_address"].as<std::string>();
    order["created_at"] = row["created_at"].as<std::string>();
    order["status"] = row["status"].as<std::string>();
    order["delivery_priority"] = row["delivery_priority"].isNull()
                                     ? Json::Value()
                                     : Json::Value(row["delivery_priority"].as<int>());
    order["total_amount"] =
        row["total_amount"].isNull() ? "0" : row["total_amount"].as<std::string>();
    order["items_count"] = row["items_count"].isNull() ? 0 : row["items_count"].as<int>();
    order["audit_note_count"] = Json::Int64(row["audit_note_count"].as<long long>());
    order["last_audit_note"] = row["last_audit_note"].isNull()
                                   ? Json::Value()
                                   : Json::Value(row["last_audit_note"].as<std::string>());
    return order;
}

void registerRoutes()
{
    const auto optionsHandler =
        [](const HttpRequestPtr &,
           std::function<void(const HttpResponsePtr &)> &&callback) {
            callback(optionsResponse());
        };
    const auto optionsHandlerWithId =
        [](const HttpRequestPtr &,
           std::function<void(const HttpResponsePtr &)> &&callback,
           long long) {
            callback(optionsResponse());
        };

    app().registerHandler("/api/oltp/orders", optionsHandler, {drogon::Options});
    app().registerHandler("/api/oltp/orders/{1}", optionsHandlerWithId, {drogon::Options});
    app().registerHandler("/api/oltp/orders/{1}/status",
                          optionsHandlerWithId,
                          {drogon::Options});
    app().registerHandler("/api/olap/revenue-by-day", optionsHandler, {drogon::Options});
    app().registerHandler("/api/olap/warehouse-turnover", optionsHandler, {drogon::Options});
    app().registerHandler("/api/log/order-status-events", optionsHandler, {drogon::Options});

    app().registerHandler(
        "/health",
        [](const HttpRequestPtr &,
           std::function<void(const HttpResponsePtr &)> &&callback) {
            Json::Value body;
            body["status"] = "ok";
            callback(jsonResponse(body));
        },
        {drogon::Get});

    app().registerHandler(
        "/api/oltp/orders/{1}",
        [](const HttpRequestPtr &,
           std::function<void(const HttpResponsePtr &)> &&callback,
           long long orderId) {
            static const std::string sql = R"SQL(
SELECT
  co.customer_order_id,
  co.customer_id,
  c.full_name,
  co.delivery_address,
  co.created_at,
  co.status::text AS status,
  co.delivery_priority,
  co.total_amount,
  co.items_count,
  audit_notes.audit_note_count,
  audit_notes.last_audit_note,
  coi.customer_order_item_id,
  coi.ordered_quantity,
  coi.sale_price,
  p.product_id,
  p.product_name,
  b.brand_name,
  pc.category_name
FROM customer_orders co
JOIN customers c ON c.customer_id = co.customer_id
JOIN customer_order_items coi ON coi.customer_order_id = co.customer_order_id
JOIN products p ON p.product_id = coi.product_id
JOIN brands b ON b.brand_id = p.brand_id
JOIN product_categories pc ON pc.category_id = p.category_id
LEFT JOIN LATERAL (
  SELECT
    count(*) AS audit_note_count,
    (array_agg(aon.note_text ORDER BY aon.created_at DESC))[1] AS last_audit_note
  FROM customer_order_audit_notes aon
  WHERE aon.customer_order_id = co.customer_order_id
) audit_notes ON true
WHERE co.customer_order_id = $1
ORDER BY coi.customer_order_item_id
)SQL";

            auto responseCallback =
                std::make_shared<std::function<void(const HttpResponsePtr &)>>(
                    std::move(callback));
            auto client = app().getDbClient();
            client->execSqlAsync(
                sql,
                [responseCallback](const Result &result) {
                    if (result.empty())
                    {
                        (*responseCallback)(
                            errorResponse("order not found", drogon::k404NotFound));
                        return;
                    }

                    Json::Value body;
                    body["order"] = orderRowToJson(result.front());
                    body["items"] = Json::arrayValue;

                    for (const auto &row : result)
                    {
                        Json::Value item;
                        item["order_item_id"] =
                            Json::Int64(row["customer_order_item_id"].as<long long>());
                        item["product_id"] = Json::Int64(row["product_id"].as<long long>());
                        item["product_name"] = row["product_name"].as<std::string>();
                        item["brand_name"] = row["brand_name"].as<std::string>();
                        item["category_name"] = row["category_name"].as<std::string>();
                        item["ordered_quantity"] = row["ordered_quantity"].as<std::string>();
                        item["sale_price"] = row["sale_price"].as<std::string>();
                        body["items"].append(item);
                    }

                    (*responseCallback)(jsonResponse(body));
                },
                [responseCallback](const DrogonDbException &error) {
                    (*responseCallback)(errorResponse(error.base().what()));
                },
                orderId);
        },
        {drogon::Get});

    app().registerHandler(
        "/api/oltp/orders",
        [](const HttpRequestPtr &,
           std::function<void(const HttpResponsePtr &)> &&callback) {
            static const std::string sql = R"SQL(
WITH selected_customer AS (
  SELECT customer_id
  FROM customers
  ORDER BY random()
  LIMIT 1
),
selected_products AS (
  SELECT
    product_id,
    row_number() OVER () AS rn,
    (row_number() OVER () + 1)::numeric(14,3) AS ordered_quantity,
    (20 + floor(random() * 150))::numeric(14,2) AS sale_price
  FROM products
  ORDER BY random()
  LIMIT 3
),
item_totals AS (
  SELECT
    sum(ordered_quantity * sale_price)::numeric(14,2) AS total_amount,
    count(*)::integer AS items_count
  FROM selected_products
),
new_order AS (
  INSERT INTO customer_orders (
    customer_id,
    delivery_address,
    created_at,
    status,
    delivery_window_start,
    delivery_window_end,
    delivery_priority,
    total_amount,
    items_count,
    last_status_changed_at
  )
  SELECT
    customer_id,
    format('Load street %s, building %s', floor(random() * 1000)::int, floor(random() * 200)::int),
    now(),
    'new'::customer_order_status,
    now() + interval '1 day',
    now() + interval '1 day 4 hours',
    1,
    item_totals.total_amount,
    item_totals.items_count,
    now()
  FROM selected_customer
  CROSS JOIN item_totals
  RETURNING customer_order_id, customer_id, delivery_address, created_at, status, total_amount, items_count
),
inserted_items AS (
  INSERT INTO customer_order_items (
    customer_order_id,
    product_id,
    ordered_quantity,
    sale_price
  )
  SELECT
    new_order.customer_order_id,
    selected_products.product_id,
    selected_products.ordered_quantity,
    selected_products.sale_price
  FROM new_order
  JOIN selected_products ON true
  RETURNING customer_order_id, ordered_quantity, sale_price
),
inserted_audit_note AS (
  INSERT INTO customer_order_audit_notes (
    customer_order_id,
    note_type,
    note_text,
    created_at
  )
  SELECT
    new_order.customer_order_id,
    'operator',
    'Order created by warehouse-api workload',
    now()
  FROM new_order
  RETURNING customer_order_id
)
SELECT
  new_order.customer_order_id,
  new_order.customer_id,
  new_order.delivery_address,
  new_order.created_at,
  new_order.status::text AS status,
  new_order.total_amount,
  new_order.items_count,
  count(inserted_items.customer_order_id) AS item_count
FROM new_order
LEFT JOIN inserted_items ON inserted_items.customer_order_id = new_order.customer_order_id
LEFT JOIN inserted_audit_note ON inserted_audit_note.customer_order_id = new_order.customer_order_id
GROUP BY
  new_order.customer_order_id,
  new_order.customer_id,
  new_order.delivery_address,
  new_order.created_at,
  new_order.status,
  new_order.total_amount,
  new_order.items_count
)SQL";

            auto responseCallback =
                std::make_shared<std::function<void(const HttpResponsePtr &)>>(
                    std::move(callback));
            auto client = app().getDbClient();
            client->execSqlAsync(
                sql,
                [responseCallback](const Result &result) {
                    if (result.empty())
                    {
                        (*responseCallback)(
                            errorResponse("seed data is missing", drogon::k409Conflict));
                        return;
                    }

                    const auto &row = result.front();
                    Json::Value body;
                    body["order_id"] = Json::Int64(row["customer_order_id"].as<long long>());
                    body["customer_id"] = Json::Int64(row["customer_id"].as<long long>());
                    body["delivery_address"] = row["delivery_address"].as<std::string>();
                    body["created_at"] = row["created_at"].as<std::string>();
                    body["status"] = row["status"].as<std::string>();
                    body["total_amount"] = row["total_amount"].as<std::string>();
                    body["items_count"] = row["items_count"].as<int>();
                    body["item_count"] = Json::Int64(row["item_count"].as<long long>());
                    (*responseCallback)(jsonResponse(body, drogon::k201Created));
                },
                [responseCallback](const DrogonDbException &error) {
                    (*responseCallback)(errorResponse(error.base().what()));
                });
        },
        {drogon::Post});

    app().registerHandler(
        "/api/oltp/orders/{1}/status",
        [](const HttpRequestPtr &request,
           std::function<void(const HttpResponsePtr &)> &&callback,
           long long orderId) {
            static const std::string sql = R"SQL(
WITH target_order AS (
  SELECT customer_order_id, status AS old_status
  FROM customer_orders
  WHERE customer_order_id = $1
  FOR UPDATE
),
updated_order AS (
  UPDATE customer_orders co
  SET status = $2::customer_order_status,
      last_status_changed_at = now()
  FROM target_order
  WHERE co.customer_order_id = target_order.customer_order_id
  RETURNING co.customer_order_id, co.status AS new_status
),
inserted_event AS (
  INSERT INTO order_status_events (
    customer_order_id,
    old_status,
    new_status,
    event_source,
    created_at
  )
  SELECT
    target_order.customer_order_id,
    target_order.old_status,
    updated_order.new_status,
    'warehouse-api',
    now()
  FROM target_order
  JOIN updated_order ON updated_order.customer_order_id = target_order.customer_order_id
  RETURNING order_status_event_id
),
inserted_audit_note AS (
  INSERT INTO customer_order_audit_notes (
    customer_order_id,
    note_type,
    note_text,
    created_at
  )
  SELECT
    target_order.customer_order_id,
    'status',
    format('Status changed from %s to %s by warehouse-api workload', target_order.old_status, updated_order.new_status),
    now()
  FROM target_order
  JOIN updated_order ON updated_order.customer_order_id = target_order.customer_order_id
  RETURNING audit_note_id
)
SELECT
  target_order.customer_order_id,
  target_order.old_status::text AS old_status,
  updated_order.new_status::text AS new_status,
  inserted_event.order_status_event_id,
  inserted_audit_note.audit_note_id
FROM target_order
JOIN updated_order ON updated_order.customer_order_id = target_order.customer_order_id
JOIN inserted_event ON true
JOIN inserted_audit_note ON true
)SQL";

            const auto status = normalizedStatus(request);
            auto responseCallback =
                std::make_shared<std::function<void(const HttpResponsePtr &)>>(
                    std::move(callback));
            auto client = app().getDbClient();
            client->execSqlAsync(
                sql,
                [responseCallback](const Result &result) {
                    if (result.empty())
                    {
                        (*responseCallback)(
                            errorResponse("order not found", drogon::k404NotFound));
                        return;
                    }

                    const auto &row = result.front();
                    Json::Value body;
                    body["order_id"] = Json::Int64(row["customer_order_id"].as<long long>());
                    body["old_status"] = row["old_status"].as<std::string>();
                    body["new_status"] = row["new_status"].as<std::string>();
                    body["event_id"] =
                        Json::Int64(row["order_status_event_id"].as<long long>());
                    body["audit_note_id"] =
                        Json::Int64(row["audit_note_id"].as<long long>());
                    (*responseCallback)(jsonResponse(body));
                },
                [responseCallback](const DrogonDbException &error) {
                    (*responseCallback)(errorResponse(error.base().what()));
                },
                orderId,
                status);
        },
        {drogon::Post});

    app().registerHandler(
        "/api/olap/revenue-by-day",
        [](const HttpRequestPtr &request,
           std::function<void(const HttpResponsePtr &)> &&callback) {
            static const std::string degradedSql = R"SQL(
WITH audit_counts AS (
  SELECT
    customer_order_id,
    count(*) AS audit_note_count
  FROM customer_order_audit_notes
  GROUP BY customer_order_id
),
order_category_revenue AS (
  SELECT
    co.customer_order_id,
    date_trunc('day', co.created_at)::date AS sales_day,
    pc.category_name,
    sum(coi.ordered_quantity * coi.sale_price) AS revenue
  FROM customer_orders co
  JOIN customer_order_items coi ON coi.customer_order_id = co.customer_order_id
  JOIN products p ON p.product_id = coi.product_id
  JOIN product_categories pc ON pc.category_id = p.category_id
  WHERE co.created_at >= $1::timestamptz
    AND co.created_at < $2::timestamptz
  GROUP BY co.customer_order_id, sales_day, pc.category_name
)
SELECT
  ocr.sales_day,
  ocr.category_name,
  count(DISTINCT ocr.customer_order_id) AS order_count,
  sum(ocr.revenue) AS revenue,
  sum(COALESCE(audit_counts.audit_note_count, 0)) AS audit_note_count
FROM order_category_revenue ocr
LEFT JOIN audit_counts ON audit_counts.customer_order_id = ocr.customer_order_id
GROUP BY ocr.sales_day, ocr.category_name
ORDER BY sales_day DESC, revenue DESC
LIMIT 100
)SQL";
            static const std::string optimizedSql = R"SQL(
SELECT
  sales_day,
  category_name,
  order_count,
  revenue,
  audit_note_count
FROM mv_revenue_by_day_category
WHERE sales_day >= ($1::timestamptz)::date
  AND sales_day < ($2::timestamptz)::date
ORDER BY sales_day DESC, revenue DESC
LIMIT 100
)SQL";

            const auto from = queryParamOrDefault(request, "from", "2020-01-01T00:00:00Z");
            const auto to = queryParamOrDefault(request, "to", "2100-01-01T00:00:00Z");
            const auto &sql = envBoolOrDefault("API_USE_REVENUE_MV", false)
                                  ? optimizedSql
                                  : degradedSql;

            auto responseCallback =
                std::make_shared<std::function<void(const HttpResponsePtr &)>>(
                    std::move(callback));
            auto client = app().getDbClient();
            client->execSqlAsync(
                sql,
                [responseCallback](const Result &result) {
                    Json::Value body;
                    body["rows"] = Json::arrayValue;
                    for (const auto &row : result)
                    {
                        Json::Value item;
                        item["sales_day"] = row["sales_day"].as<std::string>();
                        item["category_name"] = row["category_name"].as<std::string>();
                        item["order_count"] = Json::Int64(row["order_count"].as<long long>());
                        item["revenue"] = row["revenue"].as<std::string>();
                        item["audit_note_count"] =
                            Json::Int64(row["audit_note_count"].as<long long>());
                        body["rows"].append(item);
                    }
                    (*responseCallback)(jsonResponse(body));
                },
                [responseCallback](const DrogonDbException &error) {
                    (*responseCallback)(errorResponse(error.base().what()));
                },
                from,
                to);
        },
        {drogon::Get});

    app().registerHandler(
        "/api/olap/warehouse-turnover",
        [](const HttpRequestPtr &request,
           std::function<void(const HttpResponsePtr &)> &&callback) {
            static const std::string sql = R"SQL(
WITH movement_totals AS (
  SELECT
    w.warehouse_id,
    w.warehouse_name,
    p.product_id,
    p.product_name,
    sum(CASE WHEN im.movement_type = 'receipt' THEN im.quantity ELSE 0 END) AS received_quantity,
    sum(CASE WHEN im.movement_type = 'shipment' THEN im.quantity ELSE 0 END) AS shipped_quantity,
    sum(CASE WHEN im.movement_type IN ('write_off', 'adjustment') THEN im.quantity ELSE 0 END) AS adjusted_quantity
  FROM inventory_movements im
  JOIN warehouses w ON w.warehouse_id = im.warehouse_id
  JOIN products p ON p.product_id = im.product_id
  WHERE im.moved_at >= $1::timestamptz
    AND im.moved_at < $2::timestamptz
  GROUP BY w.warehouse_id, w.warehouse_name, p.product_id, p.product_name
),
ranked AS (
  SELECT
    *,
    (received_quantity + shipped_quantity + adjusted_quantity) AS total_quantity,
    dense_rank() OVER (
      PARTITION BY warehouse_id
      ORDER BY (received_quantity + shipped_quantity + adjusted_quantity) DESC
    ) AS product_rank
  FROM movement_totals
  WHERE (received_quantity + shipped_quantity + adjusted_quantity) >= $3::numeric
)
SELECT
  warehouse_id,
  warehouse_name,
  product_id,
  product_name,
  received_quantity,
  shipped_quantity,
  adjusted_quantity,
  total_quantity,
  product_rank
FROM ranked
WHERE product_rank <= 10
ORDER BY warehouse_name, product_rank, product_name
)SQL";

            const auto from = queryParamOrDefault(request, "from", "2020-01-01T00:00:00Z");
            const auto to = queryParamOrDefault(request, "to", "2100-01-01T00:00:00Z");
            const auto minQuantity = queryParamOrDefault(request, "min_quantity", "1");

            auto responseCallback =
                std::make_shared<std::function<void(const HttpResponsePtr &)>>(
                    std::move(callback));
            auto client = app().getDbClient();
            client->execSqlAsync(
                sql,
                [responseCallback](const Result &result) {
                    Json::Value body;
                    body["rows"] = Json::arrayValue;
                    for (const auto &row : result)
                    {
                        Json::Value item;
                        item["warehouse_id"] = Json::Int64(row["warehouse_id"].as<long long>());
                        item["warehouse_name"] = row["warehouse_name"].as<std::string>();
                        item["product_id"] = Json::Int64(row["product_id"].as<long long>());
                        item["product_name"] = row["product_name"].as<std::string>();
                        item["received_quantity"] = row["received_quantity"].as<std::string>();
                        item["shipped_quantity"] = row["shipped_quantity"].as<std::string>();
                        item["adjusted_quantity"] = row["adjusted_quantity"].as<std::string>();
                        item["total_quantity"] = row["total_quantity"].as<std::string>();
                        item["product_rank"] = row["product_rank"].as<int>();
                        body["rows"].append(item);
                    }
                    (*responseCallback)(jsonResponse(body));
                },
                [responseCallback](const DrogonDbException &error) {
                    (*responseCallback)(errorResponse(error.base().what()));
                },
                from,
                to,
                minQuantity);
        },
        {drogon::Get});

    app().registerHandler(
        "/api/log/order-status-events",
        [](const HttpRequestPtr &request,
           std::function<void(const HttpResponsePtr &)> &&callback) {
            static const std::string sql = R"SQL(
WITH selected_order AS (
  SELECT customer_order_id, status AS old_status
  FROM customer_orders
  ORDER BY random()
  LIMIT 1
),
inserted_event AS (
  INSERT INTO order_status_events (
    customer_order_id,
    old_status,
    new_status,
    event_source,
    created_at
  )
  SELECT
    selected_order.customer_order_id,
    selected_order.old_status,
    $1::customer_order_status,
    'k6-log-stream',
    now()
  FROM selected_order
  RETURNING order_status_event_id, customer_order_id, created_at
)
SELECT
  order_status_event_id,
  customer_order_id,
  created_at
FROM inserted_event
)SQL";

            const auto status = normalizedStatus(request);
            auto responseCallback =
                std::make_shared<std::function<void(const HttpResponsePtr &)>>(
                    std::move(callback));
            auto client = app().getDbClient();
            client->execSqlAsync(
                sql,
                [responseCallback](const Result &result) {
                    if (result.empty())
                    {
                        (*responseCallback)(
                            errorResponse("seed data is missing", drogon::k409Conflict));
                        return;
                    }

                    const auto &row = result.front();
                    Json::Value body;
                    body["event_id"] =
                        Json::Int64(row["order_status_event_id"].as<long long>());
                    body["order_id"] = Json::Int64(row["customer_order_id"].as<long long>());
                    body["created_at"] = row["created_at"].as<std::string>();
                    (*responseCallback)(jsonResponse(body, drogon::k201Created));
                },
                [responseCallback](const DrogonDbException &error) {
                    (*responseCallback)(errorResponse(error.base().what()));
                },
                status);
        },
        {drogon::Post});
}
} // namespace

int main()
{
    const auto pgHost = envOrDefault("POSTGRES_HOST", "postgres");
    const auto pgPort = envIntOrDefault("POSTGRES_PORT", 5432);
    const auto pgDb = envOrDefault("POSTGRES_DB", "warehouse");
    const auto pgUser = envOrDefault("POSTGRES_USER", "warehouse_user");
    const auto pgPassword = envOrDefault("POSTGRES_PASSWORD", "warehouse_password");
    const auto poolSize = envIntOrDefault("API_DB_POOL_SIZE", 16);
    const auto listenPort = envIntOrDefault("API_PORT", 8080);

    app().registerSyncAdvice([](const HttpRequestPtr &request) -> HttpResponsePtr {
        if (request->method() == drogon::Options)
        {
            return optionsResponse();
        }
        return nullptr;
    });
    app().registerPreSendingAdvice(
        [](const HttpRequestPtr &, const HttpResponsePtr &response) {
            response->addHeader("Access-Control-Allow-Origin", "*");
            response->addHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
            response->addHeader("Access-Control-Allow-Headers", "Content-Type");
        });

    app().createDbClient(
        "postgresql",
        pgHost,
        static_cast<unsigned short>(pgPort),
        pgDb,
        pgUser,
        pgPassword,
        static_cast<size_t>(poolSize));

    registerRoutes();

    app().addListener("0.0.0.0", static_cast<unsigned short>(listenPort))
        .setThreadNum(envIntOrDefault("API_THREADS", 4))
        .run();

    return 0;
}
