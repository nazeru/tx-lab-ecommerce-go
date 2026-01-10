package tx

import (
	"context"
	"tx-lab-ecommerce-go/internal/order/domain"
	"tx-lab-ecommerce-go/pkg/tx/common"
)

type CheckoutItem struct {
	ProductID domain.ProductID
	Quantity  int32
}

type CheckoutInput struct {
	OrderID        domain.OrderID
	CorrelationID  common.CorrelationID

	Total int64
	Items []CheckoutItem
}

type CheckoutEngine interface {
	ExecuteCheckout(ctx context.Context, in CheckoutInput) error
}
