package twopc

import (
	"tx-lab-ecommerce-go/internal/order/tx"
	"tx-lab-ecommerce-go/pkg/tx/common"
	"tx-lab-ecommerce-go/pkg/tx/twopc/coordinator"
	"tx-lab-ecommerce-go/pkg/tx/twopc/protocol"
)

type ParticipantDeps struct {
	InventoryClient common.TwoPCParticipantClient
	PaymentClient   common.TwoPCParticipantClient
	ShippingClient  common.TwoPCParticipantClient
}

func BuildParticipants(in tx.CheckoutInput, deps ParticipantDeps) []coordinator.Participant {
	lineItems := make([]protocol.LineItem, 0, len(in.Items))
	for _, it := range in.Items {
		lineItems = append(lineItems, protocol.LineItem{
			ProductID: string(it.ProductID),
			Quantity:  it.Quantity,
		})
	}

	return []coordinator.Participant{
		{
			Ref:    coordinator.ParticipantRef{Name: "inventory"},
			Client: deps.InventoryClient,
			Step:   common.StepReserveInventory,
			PayloadBuilder: func() any {
				return protocol.InventoryReservePayload{Items: lineItems}
			},
		},
		{
			Ref:    coordinator.ParticipantRef{Name: "payment"},
			Client: deps.PaymentClient,
			Step:   common.StepAuthorizePayment,
			PayloadBuilder: func() any {
				return protocol.PaymentAuthorizePayload{Amount: in.Total}
			},
		},
		{
			Ref:    coordinator.ParticipantRef{Name: "shipping"},
			Client: deps.ShippingClient,
			Step:   common.StepCreateShipment,
			PayloadBuilder: func() any {
				return protocol.ShippingCreatePayload{}
			},
		},
	}
}
