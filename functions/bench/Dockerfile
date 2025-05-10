FROM golang:1.22-alpine AS build

WORKDIR /go/src/handler
COPY . .

# Build the handler
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o handler .

FROM alpine:3.19

# Add non-root user and install dependencies
RUN apk --no-cache add ca-certificates && \
    addgroup -S app && adduser -S -g app app && \
    mkdir -p /home/app

WORKDIR /home/app

# Copy the handler binary
COPY --from=build /go/src/handler/handler .
RUN chown -R app:app ./

USER app

ENV fprocess="./handler"
EXPOSE 8080

CMD ["./handler"] 