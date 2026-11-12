module github.com/jaredzhou/mturso/tursogo

go 1.24.0

require (
	turso.tech/database/tursogo v0.8.2
	turso.tech/database/tursogo-serverless v0.0.0
)

require (
	github.com/ebitengine/purego v0.9.1 // indirect
	github.com/tursodatabase/turso-go-platform-libs v0.8.2 // indirect
	golang.org/x/sys v0.38.0 // indirect
)

replace turso.tech/database/tursogo-serverless => ./sdk
