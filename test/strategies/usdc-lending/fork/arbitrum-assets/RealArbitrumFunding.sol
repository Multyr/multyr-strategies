// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Vm} from "forge-std/Vm.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISwapRouterV3} from "@multyr-strategies/strategies/usdc-lending/swap/RewardSwapHelper.sol";
interface IMatrixFundingFeed {
    function latestRoundData() external view returns(uint80,int256,uint256,uint256,uint80);
    function decimals() external view returns(uint8);
}
interface IMatrixFundingFactory {function getPool(address,address,uint24) external view returns(address);}

/// Funding is a real holder transfer and, when needed, a real protocol swap.
/// No assumption that a holder's present balance existed at the historical pin.
abstract contract RealArbitrumFunding {
    using SafeERC20 for IERC20Metadata;
    Vm private constant fundingVm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant FUNDING_TOKEN=0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address private constant FUNDING_HOLDER=0xF977814e90dA44bFA03b6295A0616a897441aceC;
    address private constant FUNDING_WETH=0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address private constant FUNDING_ROUTER=0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address[] private fundingPools;
    event ActualMatrixFundingTransfer(address asset,address holder,uint256 beforeBalance,uint256 amount,uint256 afterBalance);
    event ActualMatrixFundingSwap(address asset,uint256 input,uint256 oracleExpected,uint256 received);
    function _fundArbitrumAsset(address asset,address assetFeed,uint256 dollars) internal returns(uint256 received) {
        IERC20Metadata input=IERC20Metadata(FUNDING_TOKEN);IERC20Metadata output=IERC20Metadata(asset);
        uint256 amountIn=dollars*1e6;uint256 beforeHolder=input.balanceOf(FUNDING_HOLDER);uint256 old=input.balanceOf(address(this));uint256 supply=input.totalSupply();
        require(beforeHolder>=amountIn,"historical genuine funding balance");fundingVm.prank(FUNDING_HOLDER);input.safeTransfer(address(this),amountIn);
        require(input.balanceOf(FUNDING_HOLDER)==beforeHolder-amountIn&&input.balanceOf(address(this))-old==amountIn&&input.totalSupply()==supply,"genuine funding conservation");
        emit ActualMatrixFundingTransfer(FUNDING_TOKEN,FUNDING_HOLDER,beforeHolder,amountIn,input.balanceOf(FUNDING_HOLDER));
        if(asset==FUNDING_TOKEN)return amountIn;
        bytes memory path;
        if(asset==0xaf88d065e77c8cC2239327C5EDb3A432268e5831){
            // The historical 100-fee stable pool holds less than $100k USDC.
            // Use the deeper actual WETH route; preserve the 1% oracle bound.
            _fundingPool(FUNDING_TOKEN,FUNDING_WETH,500);_fundingPool(FUNDING_WETH,asset,500);path=abi.encodePacked(FUNDING_TOKEN,uint24(500),FUNDING_WETH,uint24(500),asset);
        }
        else if(asset==FUNDING_WETH){_fundingPool(FUNDING_TOKEN,asset,500);path=abi.encodePacked(FUNDING_TOKEN,uint24(500),asset);}
        else {_fundingPool(FUNDING_TOKEN,FUNDING_WETH,500);_fundingPool(FUNDING_WETH,asset,500);path=abi.encodePacked(FUNDING_TOKEN,uint24(500),FUNDING_WETH,uint24(500),asset);}
        uint256 inputPrice=_fundingPrice(0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7);uint256 targetPrice=_fundingPrice(assetFeed);
        uint256 expected=Math.mulDiv(amountIn,inputPrice*10**output.decimals(),targetPrice*1e6);
        old=output.balanceOf(address(this));uint256 outputSupply=output.totalSupply();input.forceApprove(FUNDING_ROUTER,amountIn);
        received=ISwapRouterV3(FUNDING_ROUTER).exactInput(ISwapRouterV3.ExactInputParams(path,address(this),amountIn,expected*9900/10000));input.forceApprove(FUNDING_ROUTER,0);
        require(received>=expected*9900/10000&&output.balanceOf(address(this))-old==received,"real funding swap bounds");
        require(output.totalSupply()==outputSupply&&input.totalSupply()==supply,"real swap preserves supplies");
        emit ActualMatrixFundingSwap(asset,amountIn,expected,received);
    }
    function _fundingPrice(address feed) private view returns(uint256) {
        IMatrixFundingFeed f=IMatrixFundingFeed(feed);(uint80 round,int256 answer,,uint256 updated,uint80 answered)=f.latestRoundData();
        require(round>0&&answered>=round&&answer>0&&updated<=fundingVm.getBlockTimestamp()&&fundingVm.getBlockTimestamp()-updated<=1 days,"canonical funding quote");
        uint8 decimals=f.decimals();require(decimals<=18,"funding feed decimals");return uint256(answer)*10**(18-decimals);
    }
    function _fundingPool(address a,address b,uint24 fee) private {
        address pool=IMatrixFundingFactory(0x1F98431c8aD98523631AE4a59f267346ea31F984).getPool(a,b,fee);require(pool.code.length>0,"real funding pool");fundingPools.push(pool);
    }
    function _persistArbitrumFunding() internal {
        fundingVm.makePersistent(FUNDING_TOKEN);fundingVm.makePersistent(FUNDING_WETH);
        for(uint256 i;i<fundingPools.length;++i)fundingVm.makePersistent(fundingPools[i]);
    }
    function _deployArbitrumFixture(string memory artifact,bytes memory args,address asset,uint256 sequence) internal returns(address a) {
        bytes memory creation=abi.encodePacked(fundingVm.getCode(artifact),args);
        bytes32 salt=keccak256(abi.encode("ARBITRUM_CORE_ASSET_MATRIX_20261103",artifact,args,asset,sequence));
        assembly ("memory-safe"){a:=create2(0,add(creation,32),mload(creation),salt)}
        require(a.code.length>0&&a.code.length<=24576,"bounded fresh fixture runtime");
        require(IERC20Metadata(asset).balanceOf(a)==0,"fixture canonical token donation");
    }
}
