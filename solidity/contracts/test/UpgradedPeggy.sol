pragma solidity ^0.6.6;
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/proxy/Initializable.sol";
import "@nomiclabs/buidler/console.sol";

contract UpgradedPeggy is Initializable {
	using SafeMath for uint256;

	// These are updated often
	bytes32 public state_lastValsetCheckpoint;
	mapping(address => uint256) public state_lastBatchNonces;
	uint256 public state_lastValsetNonce = 0;
	uint256 public state_lastEventNonce = 0;

	// These are set once at initialization
	bytes32 public state_peggyId;
	uint256 public state_powerThreshold;

	// TransactionBatchExecutedEvent and SendToCosmosEvent both include the field _eventNonce.
	// This is incremented every time one of these events is emitted. It is checked by the
	// Cosmos module to ensure that all events are received in order, and that none are lost.
	//
	// ValsetUpdatedEvent does not include the field _eventNonce because it is never submitted to the Cosmos
	// module. It is purely for the use of relayers to allow them to successfully submit batches.
	event TransactionBatchExecutedEvent(
		uint256 indexed _batchNonce,
		address indexed _token,
		uint256 _eventNonce
	);
	event SendToCosmosEvent(
		address indexed _tokenContract,
		address indexed _sender,
		bytes32 indexed _destination,
		uint256 _amount,
		uint256 _eventNonce
	);
	event ValsetUpdatedEvent(
		uint256 indexed _newValsetNonce,
		address[] _validators,
		uint256[] _powers
	);

	// TEST FIXTURES
	// These are here to make it easier to measure gas usage. They should be removed before production
	function testMakeCheckpoint(
		address[] memory _validators,
		uint256[] memory _powers,
		uint256 _valsetNonce,
		bytes32 _peggyId
	) public pure {
		makeCheckpoint(_validators, _powers, _valsetNonce, _peggyId);
	}

	function testCheckValidatorSignatures(
		address[] memory _currentValidators,
		uint256[] memory _currentPowers,
		uint8[] memory _v,
		bytes32[] memory _r,
		bytes32[] memory _s,
		bytes32 _theHash,
		uint256 _powerThreshold
	) public pure {
		checkValidatorSignatures(
			_currentValidators,
			_currentPowers,
			_v,
			_r,
			_s,
			_theHash,
			_powerThreshold
		);
	}

	// END TEST FIXTURES

	function lastBatchNonce(address _erc20Address) public view returns (uint256) {
		return state_lastBatchNonces[_erc20Address];
	}

	// Utility function to verify geth style signatures
	function verifySig(
		address _signer,
		bytes32 _theHash,
		uint8 _v,
		bytes32 _r,
		bytes32 _s
	) public pure returns (bool) {
		bytes32 messageDigest = keccak256(
			abi.encodePacked("\x19Ethereum Signed Message:\n32", _theHash)
		);
		return _signer == ecrecover(messageDigest, _v, _r, _s);
	}

	// Make a new checkpoint from the supplied validator set
	// A checkpoint is a hash of all relevant information about the valset. This is stored by the contract,
	// instead of storing the information directly. This saves on storage and gas.
	// The format of the checkpoint is:
	// h(peggyId, "checkpoint", valsetNonce, validators[], powers[])
	// Where h is the keccak256 hash function.
	// The validator powers must be decreasing or equal. This is important for checking the signatures on the
	// next valset, since it allows the caller to stop verifying signatures once a quorum of signatures have been verified.
	function makeCheckpoint(
		address[] memory _validators,
		uint256[] memory _powers,
		uint256 _valsetNonce,
		bytes32 _peggyId
	) public pure returns (bytes32) {
		// bytes32 encoding of the string "checkpoint"
		bytes32 methodName = 0x636865636b706f696e7400000000000000000000000000000000000000000000;

		bytes32 checkpoint = keccak256(
			abi.encode(_peggyId, methodName, _valsetNonce, _validators, _powers)
		);

		return checkpoint;
	}

	function checkValidatorSignatures(
		// The current validator set and their powers
		address[] memory _currentValidators,
		uint256[] memory _currentPowers,
		// The current validator's signatures
		uint8[] memory _v,
		bytes32[] memory _r,
		bytes32[] memory _s,
		// This is what we are checking they have signed
		bytes32 _theHash,
		uint256 _powerThreshold
	) public pure returns (bool) {
		uint256 cumulativePower = 0;

		for (uint256 k = 0; k < _currentValidators.length; k = k.add(1)) {
			// If v is set to 0, this signifies that it was not possible to get a signature from this validator and we skip evaluation
			// (In a valid signature, it is either 27 or 28)
			if (_v[k] != 0) {
				// Check that the current validator has signed off on the hash
				require(
					verifySig(_currentValidators[k], _theHash, _v[k], _r[k], _s[k]),
					"Validator signature does not match."
				);

				// Sum up cumulative power
				cumulativePower = cumulativePower + _currentPowers[k];

				// Break early to avoid wasting gas
				if (cumulativePower > _powerThreshold) {
					break;
				}
			}
		}

		// Check that there was enough power
		require(
			cumulativePower > _powerThreshold,
			"Submitted validator set signatures do not have enough power."
		);
		// Success
		return true;
	}

	// This updates the valset by checking that the validators in the current valset have signed off on the
	// new valset. The signatures supplied are the signatures of the current valset over the checkpoint hash
	// generated from the new valset.
	function updateValset(
		// The new version of the validator set
		address[] memory _newValidators,
		uint256[] memory _newPowers,
		uint256 _newValsetNonce,
		// The current validators that approve the change
		address[] memory _currentValidators,
		uint256[] memory _currentPowers,
		uint256 _currentValsetNonce,
		// These are arrays of the parts of the current validator's signatures
		uint8[] memory _v,
		bytes32[] memory _r,
		bytes32[] memory _s
	) public {
		// CHECKS

		// Check that new validators and powers set is well-formed
		require(_newValidators.length == _newPowers.length, "Malformed new validator set");

		// Check that current validators, powers, and signatures (v,r,s) set is well-formed
		require(
			_currentValidators.length == _currentPowers.length &&
				_currentValidators.length == _v.length &&
				_currentValidators.length == _r.length &&
				_currentValidators.length == _s.length,
			"Malformed current validator set"
		);

		// Check that the supplied current validator set matches the saved checkpoint
		require(
			makeCheckpoint(
				_currentValidators,
				_currentPowers,
				_currentValsetNonce,
				state_peggyId
			) == state_lastValsetCheckpoint,
			"Supplied current validators and powers do not match checkpoint."
		);

		// Check that the valset nonce is greater than the old one
		require(
			_newValsetNonce > _currentValsetNonce,
			"New valset nonce must be greater than the current nonce"
		);

		// Check that enough current validators have signed off on the new validator set
		bytes32 newCheckpoint = makeCheckpoint(
			_newValidators,
			_newPowers,
			_newValsetNonce,
			state_peggyId
		);

		checkValidatorSignatures(
			_currentValidators,
			_currentPowers,
			_v,
			_r,
			_s,
			newCheckpoint,
			state_powerThreshold
		);

		// ACTIONS

		// Stored to be used next time to validate that the valset
		// supplied by the caller is correct.
		state_lastValsetCheckpoint = newCheckpoint;

		// Store new nonce
		state_lastValsetNonce = _newValsetNonce;

		// LOGS

		emit ValsetUpdatedEvent(_newValsetNonce, _newValidators, _newPowers);
	}

	function updateValsetAndSubmitBatch(
		// The new version of the validator set
		address[] memory _newValidators,
		uint256[] memory _newPowers,
		uint256 _newValsetNonce,
		// The validators that approve the batch and new valset
		address[] memory _currentValidators,
		uint256[] memory _currentPowers,
		uint256 _currentValsetNonce,
		// These are arrays of the parts of the validators signatures
		uint8[] memory _v,
		bytes32[] memory _r,
		bytes32[] memory _s,
		// The batch of transactions
		uint256[] memory _amounts,
		address[] memory _destinations,
		uint256[] memory _fees,
		uint256 _batchNonce,
		address _tokenContract
	) public {
		// CHECKS scoped to reduce stack depth
		{
			// Check that new validators and powers set is well-formed
			require(_newValidators.length == _newPowers.length, "Malformed new validator set");

			// Check that current validators, powers, and signatures (v,r,s) set is well-formed
			require(
				_currentValidators.length == _currentPowers.length &&
					_currentValidators.length == _v.length &&
					_currentValidators.length == _r.length &&
					_currentValidators.length == _s.length,
				"Malformed current validator set"
			);

			// Check that the supplied current validator set matches the saved checkpoint
			require(
				makeCheckpoint(
					_currentValidators,
					_currentPowers,
					_currentValsetNonce,
					state_peggyId
				) == state_lastValsetCheckpoint,
				"Supplied current validators and powers do not match checkpoint."
			);

			// Check that the valset nonce is greater than the old one
			require(
				_newValsetNonce > _currentValsetNonce,
				"New valset nonce must be greater than the current nonce"
			);

			// Check that the transaction batch is well-formed
			require(
				_amounts.length == _destinations.length && _amounts.length == _fees.length,
				"Malformed batch of transactions"
			);

			// Check that the batch nonce is higher than the last nonce for this token
			require(
				state_lastBatchNonces[_tokenContract] < _batchNonce,
				"New batch nonce must be greater than the current nonce"
			);

			// Make checkpoint for new valset
			bytes32 newValsetCheckpoint = makeCheckpoint(
				_newValidators,
				_newPowers,
				_newValsetNonce,
				state_peggyId
			);

			// Check that enough current validators have signed off on the transaction batch and valset
			checkValidatorSignatures(
				_currentValidators,
				_currentPowers,
				_v,
				_r,
				_s,
				// Get hash of the transaction batch and checkpoint
				keccak256(
					abi.encode(
						state_peggyId,
						// bytes32 encoding of "valsetAndTransactionBatch"
						0x76616c736574416e645472616e73616374696f6e426174636800000000000000,
						newValsetCheckpoint,
						_amounts,
						_destinations,
						_fees,
						_batchNonce,
						_tokenContract
					)
				),
				state_powerThreshold
			);

			// ACTIONS

			// Stored to be used next time to validate that the valset
			// supplied by the caller is correct.
			state_lastValsetCheckpoint = newValsetCheckpoint;
			// Store new nonce
			state_lastValsetNonce = _newValsetNonce;

			// Store batch nonce
			state_lastBatchNonces[_tokenContract] = _batchNonce;

			{
				// Send transaction amounts to destinations
				uint256 totalFee;
				for (uint256 i = 0; i < _amounts.length; i = i.add(1)) {
					IERC20(_tokenContract).transfer(_destinations[i], _amounts[i]);
					totalFee = totalFee.add(_fees[i]);
				}

				// Send transaction fees to msg.sender
				IERC20(_tokenContract).transfer(msg.sender, totalFee);
			}
		}

		// LOGS scoped to reduce stack depth
		{
			state_lastEventNonce = state_lastEventNonce.add(1);
			emit TransactionBatchExecutedEvent(_batchNonce, _tokenContract, state_lastEventNonce);
			emit ValsetUpdatedEvent(_newValsetNonce, _newValidators, _newPowers);
		}
	}

	function sendToCosmos(
		address _tokenContract,
		bytes32 _destination,
		uint256 _amount
	) public {
		IERC20(_tokenContract).transferFrom(msg.sender, address(this), _amount);
		state_lastEventNonce = state_lastEventNonce.add(1);
		emit SendToCosmosEvent(
			_tokenContract,
			msg.sender,
			_destination,
			_amount,
			state_lastEventNonce
		);
	}

	constructor() public {}

	function initialize(
		// A unique identifier for this peggy instance to use in signatures
		bytes32 _peggyId,
		// How much voting power is needed to approve operations
		uint256 _powerThreshold,
		// The validator set
		address[] calldata _validators,
		uint256[] calldata _powers
	) external initializer {
		// CHECKS

		// Check that validators, powers, and signatures (v,r,s) set is well-formed
		require(_validators.length == _powers.length, "Malformed current validator set");

		// Check cumulative power to ensure the contract has sufficient power to actually
		// pass a vote
		uint256 cumulativePower = 0;
		for (uint256 k = 0; k < _powers.length; k = k.add(1)) {
			cumulativePower = cumulativePower + _powers[k];
			if (cumulativePower > _powerThreshold) {
				break;
			}
		}
		require(
			cumulativePower > _powerThreshold,
			"Submitted validator set signatures do not have enough power."
		);

		bytes32 newCheckpoint = makeCheckpoint(_validators, _powers, 0, _peggyId);

		// ACTIONS

		state_peggyId = _peggyId;
		state_powerThreshold = _powerThreshold;
		state_lastValsetCheckpoint = newCheckpoint;
	}

	function testUpgrade() external pure returns (string memory){
		return "peggy upgrade is successful";
	}

	function getOwnAddress() external view returns (address){
		return address(this);
	}

}