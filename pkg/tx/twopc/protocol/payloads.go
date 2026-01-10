package protocol

type LineItem struct {
	ProductID string `json:"product_id"`
	Quantity  int32  `json:"quantity"`
}

type InventoryReservePayload struct {
	Items []LineItem `json:"items"`
}

type PaymentAuthorizePayload struct {
	Amount int64 `json:"amount"`
}

type ShippingCreatePayload struct {
	// можно оставить пустым на первом шаге или добавить адрес/контакты позже
}
