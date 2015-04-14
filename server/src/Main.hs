{-# LANGUAGE CPP, DataKinds, FlexibleInstances, MultiParamTypeClasses, TypeFamilies, RecordWildCards, OverloadedStrings, TemplateHaskell, TypeOperators #-}

module Main where

import           Control.Applicative
import           Control.Monad
import           Control.Monad.Reader

import           Crypto.PubKey.OpenSsh
import           Crypto.PubKey.HashDescr
import           Crypto.PubKey.RSA.PKCS15
import           Crypto.PubKey.DH
import           Crypto.Random
import           Crypto.Types.PubKey.DH

import           Data.Aeson
import qualified Data.Aeson               as A
import           Data.Aeson.TH
import qualified Data.ByteString          as B
import qualified Data.ByteString.Base64   as B64
import qualified Data.ByteString.Char8    as BC
import qualified Data.Cache.LRU           as LRU
import           Data.IORef
import           Data.Maybe
import           Data.Proxy
import           Data.Serialize.Get       (getWord32be, getWord8, runGet)
import qualified Data.Text.Encoding     as TE
import           Data.Word

import           Servant.API
import           Servant.Server
import           Web.Users.Types

import qualified Data.Text                as T

import           Network.Wai.Handler.Warp

import           Web.Stripe
import           Web.Stripe.Plan

import           Commands
import           Model

params = Params
  0xFFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A92108011A723C12A787E6D788719A10BDBA5B2699C327186AF4E23C1A946834B6150BDA2583E9CA2AD44CE8DBBBC2DB04DE8EF92E8EFC141FBECAA6287C59474E6BC05D99B2964FA090C3A2233BA186515BE7ED1F612970CEE2D7AFB81BDD762170481CD0069127D5B05AA993B4EA988D8FDDC186FFB7DC90A6C08F4DF435C93402849236C3FAB4D27C7026C1D4DCB2602646DEC9751E763DBA37BDF8FF9406AD9E530EE5DB382F413001AEB06A53ED9027D831179727B0865A8918DA3EDBEBCF9B14ED44CE6CBACED4BB1BDB7F1447E6CC254B332051512BD7AF426FB8F401378CD2BF5983CA01C64B92ECF032EA15D1721D03F482D7CE6E74FEF6D55E702F46980C82B5A84031900B1C9E59E7C97FBEC7E8F323A97A7E36CC88BE0F1D45B7FF585AC54BD407B22B4154AACC8F6D7EBF48E1D814CC5ED20F8037E0A79715EEF29BE32806A1D58BB7C5DA76F550AA3D8A1FBFF0EB19CCB1A313D55CDA56C9EC2EF29632387FE8D76E3C0468043E8F663F4860EE12BF2D5B0B7474D6E694F91E6DCC4024FFFFFFFFFFFFFFFF
  2

type Api = "info" :> Get Response
      :<|> "dh" :> ReqBody DhRequest :> Post DhResponse
      :<|> "sign" :> ReqBody DhSignRequest :> Post DhSignResponse
#ifdef DEBUG
      :<|> "print_state" :> Get ()
#endif

api :: Proxy Api
api = Proxy

data DhData = DhData
  { dhLRU   :: LRU.LRU T.Text SharedKey
  , dhCPRG  :: SystemRNG
  }

type DhState = IORef DhData

data BE = BE

instance UserStorageBackend BE where
  type UserId BE = String
  createUser bck (User {..}) = return $ Right $ T.unpack $ u_name

runServer :: UserStorageBackend bck => bck -> IO ()
runServer bck = do
  ep <- createEntropyPool
  st <- newIORef $ DhData (LRU.newLRU $ Just 10000) (cprgCreate ep)

  runServer' st
  where
    runServer' st = run 8000 $ serve api $ info
                                      :<|> dh
                                      :<|> sign
#ifdef DEBUG
                                      :<|> printState
#endif
      where
        info = do
          return $ Response $ toJSON $ cmds $ mkProxy bck

        dh DhRequest {..} = liftIO $ do
           st' <- readIORef st

           let (priv, cprg)       = generatePrivate (dhCPRG st') params
               PublicNumber svPub = calculatePublic params priv
               shared             = getShared params priv (PublicNumber dhClPub)

           modifyIORef st $ \st' -> st'
             { dhLRU  = LRU.insert dhReqUser shared $ dhLRU st'
             , dhCPRG = cprg
             }

           return $ DhResponse svPub

        sign DhSignRequest {..} = liftIO $ do
          bs  <- B.readFile "/Users/phil/.ssh/id_rsa.pub"
          st' <- readIORef st

          let (lru', shared') = LRU.delete dhClSgnUser $ dhLRU st'
              verifyUserKey UserData {..} = undefined

          writeIORef st $ st' { dhLRU = lru' }

          -- sid <- authUserByUserData bck dhSgnUser verifyUserKey 0

          -- FIXME: failing pattern matches
          let Just (SharedKey shared) = shared'
              Right (OpenSshPublicKeyRsa key _) = decodePublic bs
              Right clBlob = B64.decode $ TE.encodeUtf8 $ dhClSig

              Right (algo, sig) = flip runGet clBlob $ do
                al   <- fromIntegral <$> getWord32be
                algo <- B.pack <$> replicateM al getWord8
                sl   <- fromIntegral <$> getWord32be
                sig  <- B.pack <$> replicateM sl getWord8
                return (algo, sig)

          return $ if algo /= BC.pack "ssh-rsa"
            then SignNotOk "algo-not-ssh-rsa"
            else if verify hashDescrSHA1 key (BC.pack $ show shared) sig
              then SignOk
              else SignNotOk "verify"

#ifdef DEBUG
        printState = liftIO $ do
          readIORef st >>= print . dhLRU
          return ()
#endif
