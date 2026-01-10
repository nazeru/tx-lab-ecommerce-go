package common

import (
	"context"
	"tx-lab-ecommerce-go/pkg/tx/twopc/protocol"
)

type TwoPCParticipantClient interface {
	Prepare(ctx context.Context, req protocol.PrepareRequest) (protocol.PrepareResponse, error)
	Commit(ctx context.Context, req protocol.CommitRequest) error
	Abort(ctx context.Context, req protocol.AbortRequest) error
}
