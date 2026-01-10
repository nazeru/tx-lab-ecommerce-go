package coordinator

import (
	"context"
	"tx-lab-ecommerce-go/pkg/tx/common"
)

type ParticipantRef struct {
	Name string `json:"name"` // payment/inventory/shipping
	// можно хранить endpoint/baseURL для отладки
}

type TxLogStore interface {
	Create(ctx context.Context, txid common.TxID, orderID string, participants []ParticipantRef) error
	SetStatus(ctx context.Context, txid common.TxID, status TxStatus) error
	GetStatus(ctx context.Context, txid common.TxID) (TxStatus, error)
}
