package keeper

import (
	"github.com/althea-net/peggy/module/x/peggy/types"
	"github.com/cosmos/cosmos-sdk/codec"
	sdk "github.com/cosmos/cosmos-sdk/types"
	sdkerrors "github.com/cosmos/cosmos-sdk/types/errors"
	abci "github.com/tendermint/tendermint/abci/types"
)

// USED BY RUST:
// "custom/%s/valsetRequest/%s"
// "custom/%s/valsetConfirms/%s"
// "custom/%s/lastValsetRequests"
// "custom/%s/lastPendingValsetRequest/%s"

const (

	// Valsets

	// used in the relayer
	QueryValsetRequest                  = "valsetRequest"
	QueryValsetConfirmsByNonce          = "valsetConfirms"
	QueryLastValsetRequests             = "lastValsetRequests"
	QueryLastPendingValsetRequestByAddr = "lastPendingValsetRequest"

	// used to deploy eth contract
	QueryCurrentValset = "currentValset"
	QueryValsetConfirm = "valsetConfirm"

	// Batches

	QueryBatch                         = "batch"
	QueryLastPendingBatchRequestByAddr = "lastPendingBatchRequest"
	QueryOutgoingTxBatches             = "lastBatches"
	QueryBatchConfirms                 = "batchConfirms"

	// Other

	QueryBridgedDenominators = "allBridgedDenominators"
)

// NewQuerier is the module level router for state queries
func NewQuerier(keeper Keeper) sdk.Querier {
	return func(ctx sdk.Context, path []string, req abci.RequestQuery) (res []byte, err error) {
		switch path[0] {

		// Valsets
		case QueryCurrentValset:
			return queryCurrentValset(ctx, keeper)
		case QueryValsetRequest:
			return queryValsetRequest(ctx, path[1:], keeper)
		case QueryValsetConfirm:
			return queryValsetConfirm(ctx, path[1:], keeper)
		case QueryValsetConfirmsByNonce:
			return queryAllValsetConfirms(ctx, path[1], keeper)
		case QueryLastValsetRequests:
			return lastValsetRequests(ctx, keeper)
		case QueryLastPendingValsetRequestByAddr:
			return lastPendingValsetRequest(ctx, path[1], keeper)

		// Batches
		case QueryBatch:
			return queryBatch(ctx, path[1], path[2], keeper) // Tested (lightly)
		case QueryBatchConfirms:
			return queryAllBatchConfirms(ctx, path[1], path[2], keeper) // Tested (lightly)
		case QueryLastPendingBatchRequestByAddr:
			return lastPendingBatchRequest(ctx, path[1], keeper) // Tested (lightly)
		case QueryOutgoingTxBatches:
			return lastBatchesRequest(ctx, keeper) // Tested (lightly)

		default:
			return nil, sdkerrors.Wrapf(sdkerrors.ErrUnknownRequest, "unknown %s query endpoint", types.ModuleName)
		}
	}
}

/* USED BY RUST */
func queryValsetRequest(ctx sdk.Context, path []string, keeper Keeper) ([]byte, error) {
	nonce, err := parseNonce(path[0])
	if err != nil {
		return nil, err
	}

	valset := keeper.GetValsetRequest(ctx, nonce)
	if valset == nil {
		return nil, nil
	}
	res, err := codec.MarshalJSONIndent(keeper.cdc, *valset)
	if err != nil {
		return nil, sdkerrors.Wrap(sdkerrors.ErrJSONMarshal, err.Error())
	}

	return res, nil
}

/* USED BY RUST */
// allValsetConfirmsByNonce returns all the confirm messages for a given nonce
// When nothing found an empty json array is returned. No pagination.
func queryAllValsetConfirms(ctx sdk.Context, nonceStr string, keeper Keeper) ([]byte, error) {
	nonce, err := parseNonce(nonceStr)
	if err != nil {
		return nil, sdkerrors.Wrap(sdkerrors.ErrInvalidRequest, err.Error())
	}

	var confirms []types.MsgValsetConfirm
	keeper.IterateValsetConfirmByNonce(ctx, nonce, func(_ []byte, c types.MsgValsetConfirm) bool {
		confirms = append(confirms, c)
		return false
	})
	if len(confirms) == 0 {
		return nil, nil
	}
	res, err := codec.MarshalJSONIndent(keeper.cdc, confirms)
	if err != nil {
		return nil, sdkerrors.Wrap(sdkerrors.ErrJSONMarshal, err.Error())
	}

	return res, nil
}

// USED BY RUST
// allBatchConfirms returns all the confirm messages for a given nonce
// When nothing found an empty json array is returned. No pagination.
func queryAllBatchConfirms(ctx sdk.Context, nonceStr string, tokenContractString string, keeper Keeper) ([]byte, error) {
	nonce, err := parseNonce(nonceStr)
	if err != nil {
		return nil, sdkerrors.Wrap(sdkerrors.ErrInvalidRequest, err.Error())
	}
	tokenContract := types.NewEthereumAddress(tokenContractString)

	var confirms []types.MsgConfirmBatch
	keeper.IterateBatchConfirmByNonceAndTokenContract(ctx, nonce, tokenContract, func(_ []byte, c types.MsgConfirmBatch) bool {
		confirms = append(confirms, c)
		return false
	})
	if len(confirms) == 0 {
		return nil, nil
	}
	res, err := codec.MarshalJSONIndent(keeper.cdc, confirms)
	if err != nil {
		return nil, sdkerrors.Wrap(sdkerrors.ErrJSONMarshal, err.Error())
	}

	return res, nil
}

const maxValsetRequestsReturned = 5

/* USED BY RUST */
// lastValsetRequests returns up to maxValsetRequestsReturned valsets from the store
func lastValsetRequests(ctx sdk.Context, keeper Keeper) ([]byte, error) {
	var counter int
	var valReq []types.Valset
	keeper.IterateValsetRequest(ctx, func(_ []byte, val types.Valset) bool {
		valReq = append(valReq, val)
		counter++
		return counter >= maxValsetRequestsReturned
	})
	if len(valReq) == 0 {
		return nil, nil
	}
	res, err := codec.MarshalJSONIndent(keeper.cdc, valReq)
	if err != nil {
		return nil, sdkerrors.Wrap(sdkerrors.ErrJSONMarshal, err.Error())
	}
	return res, nil
}

/* USED BY RUST */
// lastPendingValsetRequest gets the oldest valset that operatorAddr has not yet signed
func lastPendingValsetRequest(ctx sdk.Context, operatorAddr string, keeper Keeper) ([]byte, error) {
	addr, err := sdk.AccAddressFromBech32(operatorAddr)
	if err != nil {
		return nil, sdkerrors.Wrap(sdkerrors.ErrInvalidRequest, "address invalid")
	}

	var pendingValsetReq *types.Valset
	keeper.IterateValsetRequest(ctx, func(_ []byte, val types.Valset) bool {
		// foundConfirm is true if the operatorAddr has signed the valset we are currently looking at
		foundConfirm := keeper.GetValsetConfirm(ctx, val.Nonce, addr) != nil
		// if this valset has NOT been signed by operatorAddr, store it in pendingValsetReq
		// and exit the loop
		if !foundConfirm {
			pendingValsetReq = &val
			return true
		}
		// return false to continue the loop
		return false
	})
	if pendingValsetReq == nil {
		return nil, nil
	}
	res, err := codec.MarshalJSONIndent(keeper.cdc, pendingValsetReq)
	if err != nil {
		return nil, sdkerrors.Wrap(sdkerrors.ErrJSONMarshal, err.Error())
	}
	return res, nil
}

func queryCurrentValset(ctx sdk.Context, keeper Keeper) ([]byte, error) {
	valset := keeper.GetCurrentValset(ctx)
	res, err := codec.MarshalJSONIndent(keeper.cdc, valset)
	if err != nil {
		return nil, sdkerrors.Wrap(sdkerrors.ErrJSONMarshal, err.Error())
	}

	return res, nil
}

// USED BY RUST //
// queryValsetConfirm returns the confirm msg for single orchestrator address and nonce
// When nothing found a nil value is returned
func queryValsetConfirm(ctx sdk.Context, path []string, keeper Keeper) ([]byte, error) {
	nonce, err := parseNonce(path[0])
	if err != nil {
		return nil, sdkerrors.Wrap(sdkerrors.ErrInvalidRequest, err.Error())
	}

	accAddress, err := sdk.AccAddressFromBech32(path[1])
	if err != nil {
		return nil, sdkerrors.Wrap(sdkerrors.ErrInvalidRequest, err.Error())
	}

	valset := keeper.GetValsetConfirm(ctx, nonce, accAddress)
	if valset == nil {
		return nil, nil
	}
	res, err := codec.MarshalJSONIndent(keeper.cdc, *valset)
	if err != nil {
		return nil, sdkerrors.Wrap(sdkerrors.ErrJSONMarshal, err.Error())
	}

	return res, nil
}

type MultiSigUpdateResponse struct {
	Valset     types.Valset `json:"valset"`
	Signatures [][]byte     `json:"signatures,omitempty"`
}

// USED BY RUST //
// lastPendingBatchRequest gets the latest batch that has NOT been signed by operatorAddr
func lastPendingBatchRequest(ctx sdk.Context, operatorAddr string, keeper Keeper) ([]byte, error) {
	addr, err := sdk.AccAddressFromBech32(operatorAddr)
	if err != nil {
		return nil, sdkerrors.Wrap(sdkerrors.ErrInvalidRequest, "address invalid")
	}

	var pendingBatchReq *types.OutgoingTxBatch
	keeper.IterateOutgoingTXBatches(ctx, func(_ []byte, batch types.OutgoingTxBatch) bool {
		foundConfirm := keeper.GetBatchConfirm(ctx, batch.Nonce, batch.TokenContract, addr) != nil
		if !foundConfirm {
			pendingBatchReq = &batch
			return true
		}
		return false
	})
	if pendingBatchReq == nil {
		return nil, nil
	}
	res, err := codec.MarshalJSONIndent(keeper.cdc, pendingBatchReq)
	if err != nil {
		return nil, sdkerrors.Wrap(sdkerrors.ErrJSONMarshal, err.Error())
	}
	return res, nil
}

// We can assume that the signatures and the valset members are sorted
// in the same order but this is insufficient for a relayer to actually
// relay the batch. Since a batch may pass without signatures from some
// validators we need some metadata to know who the signatures are from.
// So that we can properly pass a blank signature for a specific validator
type SignatureWithAddress struct {
	Signature string                `json:"eth_signature"`
	Address   types.EthereumAddress `json:"eth_address"`
}

type SignedOutgoingTxBatchResponse struct {
	Batch      types.OutgoingTxBatch  `json:"batch"`
	Signatures []SignatureWithAddress `json:"signatures,omitempty"`
}

const MaxResults = 100 // todo: impl pagination

// USED BY RUST //
// Gets MaxResults batches from store. Does not select by token type or anything
func lastBatchesRequest(ctx sdk.Context, keeper Keeper) ([]byte, error) {
	var batches []types.OutgoingTxBatch
	keeper.IterateOutgoingTXBatches(ctx, func(_ []byte, batch types.OutgoingTxBatch) bool {
		batches = append(batches, batch)
		return len(batches) == MaxResults
	})
	if len(batches) == 0 {
		return nil, nil
	}
	res, err := codec.MarshalJSONIndent(keeper.cdc, batches)
	if err != nil {
		return nil, sdkerrors.Wrap(sdkerrors.ErrJSONMarshal, err.Error())
	}
	return res, nil
}

// USED BY RUST //
// queryBatch gets a batch by tokenContract and nonce
func queryBatch(ctx sdk.Context, nonce string, tokenContract string, keeper Keeper) ([]byte, error) {
	parsedNonce, err := parseNonce(nonce)
	if err != nil {
		return nil, sdkerrors.Wrap(sdkerrors.ErrUnknownRequest, err.Error())
	}

	contractAddress := types.NewEthereumAddress(tokenContract)
	if contractAddress.ValidateBasic() != nil {
		return nil, sdkerrors.Wrap(sdkerrors.ErrUnknownRequest, err.Error())
	}

	foundBatch := keeper.GetOutgoingTXBatch(ctx, contractAddress, parsedNonce)
	if foundBatch == nil {
		return nil, sdkerrors.Wrap(sdkerrors.ErrUnknownRequest, "Can not find tx batch")
	}
	res, err := codec.MarshalJSONIndent(keeper.cdc, foundBatch)
	if err != nil {
		return nil, sdkerrors.Wrap(sdkerrors.ErrUnknownRequest, err.Error())
	}
	return res, nil
}

func parseNonce(nonceArg string) (types.UInt64Nonce, error) {
	return types.UInt64NonceFromString(nonceArg)
}
