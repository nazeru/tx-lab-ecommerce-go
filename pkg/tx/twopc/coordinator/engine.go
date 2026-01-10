package coordinator

import (
	"context"
	"errors"
	"tx-lab-ecommerce-go/pkg/tx/common"
	"tx-lab-ecommerce-go/pkg/tx/twopc/protocol"
)

type Participant struct {
	Ref    ParticipantRef
	Client common.TwoPCParticipantClient
	Step   common.StepName
	// PayloadBuilder строит payload для PREPARE конкретного участника
	PayloadBuilder func() any
}

type Engine struct {
	Log TxLogStore
}

func (e *Engine) Execute(ctx context.Context, txid common.TxID, orderID string, correlationID common.CorrelationID, parts []Participant) error {
	if err := e.Log.Create(ctx, txid, orderID, mapRefs(parts)); err != nil {
		return err
	}
	_ = e.Log.SetStatus(ctx, txid, TxPreparing)

	// Phase 1: PREPARE
	prepared := make([]Participant, 0, len(parts))
	for _, p := range parts {
		resp, err := p.Client.Prepare(ctx, protocol.PrepareRequest{
			TxID:          txid,
			OrderID:       orderID,
			Step:          p.Step,
			CorrelationID: correlationID,
			Payload:       p.PayloadBuilder(),
		})
		if err != nil || !resp.VoteYes {
			_ = e.Log.SetStatus(ctx, txid, TxAborting)
			// abort всех, кто успел подготовиться
			for i := len(prepared) - 1; i >= 0; i-- {
				_ = prepared[i].Client.Abort(ctx, protocol.AbortRequest{TxID: txid})
			}
			_ = e.Log.SetStatus(ctx, txid, TxAborted)
			if err != nil {
				return err
			}
			return errors.New(resp.Reason)
		}
		prepared = append(prepared, p)
	}

	// Phase 2: COMMIT
	_ = e.Log.SetStatus(ctx, txid, TxCommitting)
	for _, p := range prepared {
		if err := p.Client.Commit(ctx, protocol.CommitRequest{TxID: txid}); err != nil {
			// Для “минимального” 2PC на демо достаточно ретраев.
			// Полноценное решение требует восстановления по журналу.
			return err
		}
	}
	_ = e.Log.SetStatus(ctx, txid, TxCommitted)
	return nil
}

func mapRefs(parts []Participant) []ParticipantRef {
	out := make([]ParticipantRef, 0, len(parts))
	for _, p := range parts {
		out = append(out, p.Ref)
	}
	return out
}
