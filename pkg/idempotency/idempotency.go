package idempotency

import (
	"net/http"
	"strings"
)

const Header = "Idempotency-Key"

func Key(r *http.Request) string {
	return strings.TrimSpace(r.Header.Get(Header))
}
