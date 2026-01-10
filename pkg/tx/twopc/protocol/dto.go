package protocol

import "tx-lab-ecommerce-go/pkg/tx/common"

type PrepareRequest struct {
	TxID          common.TxID          `json:"tx_id"`
	OrderID       string               `json:"order_id"`
	Step          common.StepName      `json:"step"`
	CorrelationID common.CorrelationID `json:"correlation_id"`
	Payload       any                  `json:"payload"`
}

type PrepareResponse struct {
	VoteYes bool   `json:"vote_yes"`
	Reason  string `json:"reason,omitempty"`
}

type CommitRequest struct {
	TxID common.TxID `json:"tx_id"`
}

type AbortRequest struct {
	TxID common.TxID `json:"tx_id"`
}
