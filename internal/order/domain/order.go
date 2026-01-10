package domain

import "time"

type OrderID string
type ProductID string

type OrderStatus string

const (
	OrderStatusPending    OrderStatus = "PENDING"
	OrderStatusProcessing OrderStatus = "PROCESSING"
	OrderStatusConfirmed  OrderStatus = "CONFIRMED"
	OrderStatusRejected   OrderStatus = "REJECTED"
	OrderStatusCancelled  OrderStatus = "CANCELLED"
)

type OrderItem struct {
	ProductID ProductID
	Quantity  int32
}

type Order struct {
	ID     OrderID
	Status OrderStatus
	Total  int64 // в минимальных единицах (копейки/центы)
	Items  []OrderItem

	CreatedAt time.Time
	UpdatedAt time.Time
}
