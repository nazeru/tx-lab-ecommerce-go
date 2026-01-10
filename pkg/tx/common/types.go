package common

import "time"

type TxMode string

const (
	TxMode2PC      TxMode = "twopc"
	TxModeTCC      TxMode = "tcc"
	TxModeSagaOrch TxMode = "saga_orch"
	TxModeSagaChor TxMode = "saga_chor"
)

type TxStatus string

const (
	TxStarted    TxStatus = "STARTED"
	TxPreparing  TxStatus = "PREPARING"
	TxCommitting TxStatus = "COMMITTING"
	TxAborting   TxStatus = "ABORTING"
	TxCommitted  TxStatus = "COMMITTED"
	TxAborted    TxStatus = "ABORTED"
)

type TxID string // можно UUID строкой; если используете uuid.UUID — замените тип

type CorrelationID string

type StepName string

// Для order-checkout удобно фиксировать шаги так:
const (
	StepReserveInventory StepName = "reserve_inventory"
	StepAuthorizePayment StepName = "authorize_payment"
	StepCreateShipment   StepName = "create_shipment"
)

type Deadline struct {
	At time.Time
}
