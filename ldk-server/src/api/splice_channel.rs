use crate::api::error::LdkServerError;
use crate::api::error::LdkServerErrorCode::InvalidRequestError;
use crate::service::Context;
use ldk_node::bitcoin::secp256k1::PublicKey;
use ldk_node::bitcoin::Address;
use ldk_node::UserChannelId;
use ldk_server_protos::api::{
	SpliceInRequest, SpliceInResponse, SpliceOutRequest, SpliceOutResponse,
};
use std::str::FromStr;

pub(crate) const SPLICE_IN_PATH: &str = "SpliceIn";

pub(crate) fn handle_splice_in_request(
	context: Context, request: SpliceInRequest,
) -> Result<SpliceInResponse, LdkServerError> {
	let user_channel_id = parse_user_channel_id(&request.user_channel_id)?;
	let counterparty_node_id = parse_counterparty_node_id(&request.counterparty_node_id)?;

	context.node.splice_in(&user_channel_id, counterparty_node_id, request.splice_amount_sats)?;

	Ok(SpliceInResponse {})
}

pub(crate) const SPLICE_OUT_PATH: &str = "SpliceOut";

pub(crate) fn handle_splice_out_request(
	context: Context, request: SpliceOutRequest,
) -> Result<SpliceOutResponse, LdkServerError> {
	let user_channel_id = parse_user_channel_id(&request.user_channel_id)?;
	let counterparty_node_id = parse_counterparty_node_id(&request.counterparty_node_id)?;

	let address = request
		.address
		.map(|address| {
			Address::from_str(&address)
				.and_then(|address| address.require_network(context.node.config().network))
				.map_err(|_| ldk_node::NodeError::InvalidAddress)
		})
		.unwrap_or_else(|| context.node.onchain_payment().new_address())
		.map_err(|_| {
			LdkServerError::new(
				InvalidRequestError,
				"Address is not valid for LdkServer's configured network.".to_string(),
			)
		})?;
	let address_str = address.to_string();

	context.node.splice_out(
		&user_channel_id,
		counterparty_node_id,
		address,
		request.splice_amount_sats,
	)?;

	Ok(SpliceOutResponse { address: address_str })
}

fn parse_user_channel_id(id: &str) -> Result<UserChannelId, LdkServerError> {
	let parsed = id.parse::<u128>().map_err(|_| {
		LdkServerError::new(InvalidRequestError, "Invalid UserChannelId.".to_string())
	})?;
	Ok(UserChannelId(parsed))
}

fn parse_counterparty_node_id(id: &str) -> Result<PublicKey, LdkServerError> {
	PublicKey::from_str(id).map_err(|e| {
		LdkServerError::new(
			InvalidRequestError,
			format!("Invalid counterparty node ID, error: {}", e),
		)
	})
}
