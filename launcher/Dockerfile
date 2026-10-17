FROM --platform=$BUILDPLATFORM golang:1.26.1 AS build
ARG TARGETARCH
ENV CGO_ENABLED=0 GOTOOLCHAIN=local
WORKDIR /src
COPY go.mod *.go ./
RUN GOARCH=$TARGETARCH go build -o /launcher .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /launcher /launcher
ENTRYPOINT ["/launcher"]
