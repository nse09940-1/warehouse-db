FROM drogonframework/drogon:latest AS builder

WORKDIR /app

COPY workload/CMakeLists.txt ./CMakeLists.txt
COPY workload/src ./src

RUN cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
    && cmake --build build --config Release -j

FROM drogonframework/drogon:latest

WORKDIR /app

COPY --from=builder /app/build/warehouse-api /usr/local/bin/warehouse-api

EXPOSE 8080

ENV API_PORT=8080

CMD ["warehouse-api"]
