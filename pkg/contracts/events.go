package contracts

import "time"

type Event struct {
	EventID   string         `json:"event_id"`
	TxID      string         `json:"txid"`
	OrderID   string         `json:"order_id"`
	CreatedAt time.Time      `json:"created_at"`
	Type      string         `json:"type"`
	Payload   map[string]any `json:"payload"`
}

const (
	EventOrderCreated        = "order.created"
	EventInventorySoft       = "inventory.soft_reserved"
	EventPaymentCreated      = "payment.created"
	EventPaymentCaptured     = "payment.captured"
	EventInventoryHard       = "inventory.hard_reserved"
	EventShipmentCreated     = "shipping.created"
	EventOrderConfirmed      = "order.confirmed"
	EventOrderShipped        = "order.shipped"
	EventShipmentDelivered   = "shipping.delivered"
	EventInventoryDeducted   = "inventory.deducted"
	EventOrderCompleted      = "order.completed"
	EventOrderCompensated    = "order.compensated"
	EventPaymentRefunded     = "payment.refunded"
	EventInventoryReleased   = "inventory.released"
	EventShipmentCancelled   = "shipping.cancelled"
	EventNotificationEmitted = "notification.emitted"
)
