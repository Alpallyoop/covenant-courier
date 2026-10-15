using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

// VTP v2 reference implementation. See spec/VTP_V2_SECURITY_PROTOCOL.md.
// Every failure is reported as a single stable token on stderr with exit code 42
// (protocol/verification failure) or 1 (internal failure). Nothing fails open.
try
{
    if (args.Length == 0) throw new VtpException("VTP2_USAGE");
    var a = Args.Parse(args.Skip(1).ToArray());
    using var commandLock = a.Has("state") ? StateStore.Lock(a.Need("state")) : null;
    switch (args[0].ToLowerInvariant())
    {
        case "init": Commands.Init(a); break;
        case "bundle": Commands.Bundle(a); break;
        case "rotate": Commands.Rotate(a); break;
        case "trust": Commands.Trust(a); break;
        case "fingerprint": Commands.FingerprintOf(a); break;
        case "session-init": Commands.SessionInit(a); break;
        case "session-accept": Commands.SessionAccept(a); break;
        case "encrypt": Commands.Encrypt(a); break;
        case "decrypt": Commands.Decrypt(a); break;
        case "inspect": Commands.Inspect(a); break;
        case "status": Commands.Status(a); break;
        case "kat": Commands.KnownAnswerTests(); break;
        default: throw new VtpException("VTP2_UNKNOWN_COMMAND");
    }
}
catch (VtpException e) { Console.Error.WriteLine(e.Message); return 42; }
catch (CryptographicException) { Console.Error.WriteLine("VTP2_CRYPTOGRAPHIC_FAILURE"); return 42; }
catch (JsonException) { Console.Error.WriteLine("VTP2_INVALID_JSON"); return 42; }
catch (InvalidOperationException) { Console.Error.WriteLine("VTP2_INVALID_FIELD_TYPE"); return 42; }
catch (FormatException) { Console.Error.WriteLine("VTP2_INVALID_FIELD_TYPE"); return 42; }
catch (Exception e) { Console.Error.WriteLine("VTP2_INTERNAL_FAILURE:" + e.GetType().Name); return 1; }
return 0;

sealed class VtpException(string message) : Exception(message);

static class Protocol
{
    public const string Suite = "VTP2-P256-HKDFSHA256-CHACHA20POLY1305";
    public const int MaxInput = 1024 * 1024;
    public const int MaxPlain = 768 * 1024 - 4096; // leaves room for the envelope header within MaxInput after base64
    public const int MaxSkippedKeys = 100;
    public const int OneTimePrekeyPool = 20;
    public const int ReplayJournal = 4096;
    public static readonly TimeSpan BundleLifetime = TimeSpan.FromDays(30);
    public static readonly TimeSpan MessageLifetime = TimeSpan.FromDays(7);
    public static readonly TimeSpan ClockSkew = TimeSpan.FromMinutes(10);

    // Closed field sets: anything else in a security-relevant structure fails closed.
    public static readonly string[] BundleFields = ["schema","suite","device_id","sequence","expires_utc","identity_sign_public_b64","identity_dh_public_b64","signed_prekey_public_b64","one_time_prekeys","signature_b64"];
    public static readonly string[] OpkFields = ["id","public_b64"];
    public static readonly string[] SessionInitFields = ["schema","suite","session_id","created_utc","initiator_bundle","recipient_device_id","recipient_fingerprint","recipient_bundle_sequence","ephemeral_public_b64","one_time_prekey_id","signature_b64"];
    public static readonly string[] MessageFields = ["schema","suite","session_id","sender_device_id","recipient_device_id","message_id","message_number","created_utc","expires_utc","content_type","nonce_b64","ciphertext_length","ciphertext_b64","tag_b64"];
}

sealed class Args
{
    readonly Dictionary<string,string> values = new(StringComparer.OrdinalIgnoreCase);
    public static Args Parse(string[] args)
    {
        var result = new Args();
        for (var i=0; i<args.Length; i+=2)
        {
            if (!args[i].StartsWith("--", StringComparison.Ordinal) || i+1 >= args.Length)
                throw new VtpException("VTP2_BAD_ARGUMENTS");
            if (!result.values.TryAdd(args[i][2..], args[i+1])) throw new VtpException("VTP2_DUPLICATE_ARGUMENT");
        }
        return result;
    }
    public string Need(string name) => values.TryGetValue(name, out var v) && !string.IsNullOrWhiteSpace(v) ? v : throw new VtpException("VTP2_MISSING_ARGUMENT:"+name);
    public string Get(string name, string fallback) => values.TryGetValue(name, out var v) ? v : fallback;
    public bool Has(string name) => values.ContainsKey(name);
}

sealed class DeviceState
{
    public int Version { get; set; } = 2;
    public required string DeviceId { get; set; }
    public required string SignPrivate { get; set; }
    public required string DhPrivate { get; set; }
    public required string SignedPrekeyPrivate { get; set; }
    // The signed prekey of the previous bundle sequence, kept for one rotation so that
    // session requests made against the previous bundle can still be accepted.
    public string? PreviousSignedPrekeyPrivate { get; set; }
    public long PreviousBundleSequence { get; set; }
    public long BundleSequence { get; set; } = 1;
    public required string BundleExpiresUtc { get; set; }
    public Dictionary<string,string> OneTimePrekeys { get; set; } = [];
    public Dictionary<string,TrustedDevice> Trusted { get; set; } = [];
    public Dictionary<string,SessionState> Sessions { get; set; } = [];
}
sealed class TrustedDevice
{
    public required string Fingerprint { get; set; }
    public required string SignPublic { get; set; }
    public required string DhPublic { get; set; }
    public long LastBundleSequence { get; set; }
}
sealed class SessionState
{
    public required string SessionId { get; set; }
    public required string PeerDeviceId { get; set; }
    public required string PeerFingerprint { get; set; }
    public required string RootKey { get; set; }
    public required string SendChain { get; set; }
    public required string ReceiveChain { get; set; }
    public ulong SendNumber { get; set; }
    public ulong ReceiveNumber { get; set; }
    public Dictionary<string,string> SkippedKeys { get; set; } = [];
    public List<string> SeenMessageIds { get; set; } = [];
}

static class Commands
{
    const string Suite = Protocol.Suite;

    public static void Init(Args a)
    {
        var path = Path.GetFullPath(a.Need("state"));
        if (File.Exists(path)) throw new VtpException("VTP2_STATE_EXISTS");
        var deviceId = ValidateId(a.Need("device"), "DEVICE_ID");
        using var sign = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        using var dh = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
        using var spk = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
        var state = new DeviceState {
            DeviceId=deviceId, SignPrivate=B64(sign.ExportPkcs8PrivateKey()), DhPrivate=B64(dh.ExportPkcs8PrivateKey()),
            SignedPrekeyPrivate=B64(spk.ExportPkcs8PrivateKey()), BundleExpiresUtc=Now().Add(Protocol.BundleLifetime).ToString("O")
        };
        Replenish(state);
        StateStore.Save(path,state);
        Console.WriteLine("VTP2_INIT_OK:"+deviceId);
    }

    public static void Bundle(Args a)
    {
        var state=StateStore.Load(a.Need("state"));
        if (ParseTime(state.BundleExpiresUtc) < Now()) throw new VtpException("VTP2_OWN_BUNDLE_EXPIRED_ROTATE_REQUIRED");
        var body=SignedBundle(state);
        SafeFile.WriteJson(a.Need("out"),body);
        Console.WriteLine("VTP2_BUNDLE_OK:"+Fingerprint((string)body["identity_sign_public_b64"]!));
    }

    // Rotates the signed prekey, refills the one-time prekey pool, advances the bundle
    // sequence and extends expiry. Identity keys never change here; an identity change is
    // a new device and must go through an explicit trust ceremony.
    public static void Rotate(Args a)
    {
        var statePath=a.Need("state"); var state=StateStore.Load(statePath);
        using var spk = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
        state.PreviousSignedPrekeyPrivate = state.SignedPrekeyPrivate;
        state.PreviousBundleSequence = state.BundleSequence;
        state.SignedPrekeyPrivate = B64(spk.ExportPkcs8PrivateKey());
        state.BundleSequence = checked(state.BundleSequence + 1);
        state.BundleExpiresUtc = Now().Add(Protocol.BundleLifetime).ToString("O");
        Replenish(state);
        StateStore.Save(statePath,state);
        Console.WriteLine("VTP2_ROTATE_OK:"+state.BundleSequence);
    }

    public static void FingerprintOf(Args a)
    {
        var bundle=ReadObject(a.Need("bundle")); ValidateBundle(bundle);
        Console.WriteLine("VTP2_FINGERPRINT:"+Fingerprint(NeedString(bundle,"identity_sign_public_b64")));
    }

    public static void Trust(Args a)
    {
        var statePath=a.Need("state"); var state=StateStore.Load(statePath);
        var bundle=ReadObject(a.Need("bundle")); ValidateBundle(bundle);
        var fingerprint=Fingerprint(NeedString(bundle,"identity_sign_public_b64"));
        if(!CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(fingerprint),Encoding.ASCII.GetBytes(a.Need("fingerprint").ToLowerInvariant())))
            throw new VtpException("VTP2_FINGERPRINT_MISMATCH");
        var peer=ValidateId(NeedString(bundle,"device_id"),"DEVICE_ID");
        if(peer==state.DeviceId) throw new VtpException("VTP2_CANNOT_TRUST_SELF");
        var sequence=NeedLong(bundle,"sequence");
        if(state.Trusted.TryGetValue(peer,out var prior))
        {
            if(prior.Fingerprint!=fingerprint) throw new VtpException("VTP2_IDENTITY_CHANGED");
            if(sequence<prior.LastBundleSequence) throw new VtpException("VTP2_BUNDLE_ROLLBACK");
        }
        state.Trusted[peer]=new(){Fingerprint=fingerprint,SignPublic=NeedString(bundle,"identity_sign_public_b64"),DhPublic=NeedString(bundle,"identity_dh_public_b64"),LastBundleSequence=sequence};
        StateStore.Save(statePath,state); Console.WriteLine("VTP2_TRUST_OK:"+peer);
    }

    public static void SessionInit(Args a)
    {
        var statePath=a.Need("state"); var state=StateStore.Load(statePath); var peerBundle=ReadObject(a.Need("peer-bundle")); ValidateBundle(peerBundle);
        var peerId=NeedString(peerBundle,"device_id"); RequireTrusted(state,peerBundle);
        var peerSequence=NeedLong(peerBundle,"sequence");
        if(peerSequence<state.Trusted[peerId].LastBundleSequence) throw new VtpException("VTP2_BUNDLE_ROLLBACK");
        var opks=peerBundle["one_time_prekeys"] as JsonArray ?? throw new VtpException("VTP2_BUNDLE_NO_OPK");
        if(opks.Count==0) throw new VtpException("VTP2_BUNDLE_NO_OPK");
        // A random choice keeps two initiators holding the same bundle copy from colliding.
        var opk=opks[RandomNumberGenerator.GetInt32(opks.Count)] as JsonObject ?? throw new VtpException("VTP2_BAD_OPK");
        RequireExactFields(opk,Protocol.OpkFields,"OPK"); var opkId=ValidateId(NeedString(opk,"id"),"OPK_ID");
        using var eph=ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
        var ownBundle=SignedBundle(state);
        var sessionId=RandomId();
        var body=new JsonObject{{"schema","vtp.session_init.v2"},{"suite",Suite},{"session_id",sessionId},{"created_utc",Now().ToString("O")},{"initiator_bundle",ownBundle},{"recipient_device_id",peerId},{"recipient_fingerprint",Fingerprint(NeedString(peerBundle,"identity_sign_public_b64"))},{"recipient_bundle_sequence",peerSequence},{"ephemeral_public_b64",B64(eph.ExportSubjectPublicKeyInfo())},{"one_time_prekey_id",opkId}};
        using(var s=LoadSign(state.SignPrivate)) body["signature_b64"]=B64(s.SignData(Canonical.Bytes(body),HashAlgorithmName.SHA256));
        var secret=InitiatorSecret(state,eph,peerBundle,NeedString(opk,"public_b64"));
        var keys=DeriveInitial(secret,Transcript(body)); CryptographicOperations.ZeroMemory(secret);
        state.Sessions[sessionId]=NewSession(sessionId,peerId,Fingerprint(NeedString(peerBundle,"identity_sign_public_b64")),keys,true);
        state.Trusted[peerId].LastBundleSequence=peerSequence;
        StateStore.Save(statePath,state); SafeFile.WriteJson(a.Need("out"),body); Console.WriteLine("VTP2_SESSION_INIT_OK:"+sessionId);
    }

    public static void SessionAccept(Args a)
    {
        var statePath=a.Need("state"); var state=StateStore.Load(statePath); var req=ReadObject(a.Need("request"));
        RequireExactFields(req,Protocol.SessionInitFields,"SESSION_INIT");
        Expect(req,"schema","vtp.session_init.v2"); Expect(req,"suite",Suite);
        if(NeedString(req,"recipient_device_id")!=state.DeviceId) throw new VtpException("VTP2_WRONG_RECIPIENT");
        var bundle=req["initiator_bundle"] as JsonObject ?? throw new VtpException("VTP2_BAD_INITIATOR_BUNDLE"); ValidateBundle(bundle); RequireTrusted(state,bundle);
        VerifySignedObject(req,NeedString(bundle,"identity_sign_public_b64"));
        using(var own=LoadSign(state.SignPrivate))
            if(NeedString(req,"recipient_fingerprint")!=Fingerprint(B64(own.ExportSubjectPublicKeyInfo()))) throw new VtpException("VTP2_WRONG_RECIPIENT_FINGERPRINT");
        if(ParseTime(NeedString(req,"created_utc"))>Now().Add(Protocol.ClockSkew)) throw new VtpException("VTP2_REQUEST_FROM_FUTURE");
        var sessionId=ValidateId(NeedString(req,"session_id"),"SESSION_ID"); if(state.Sessions.ContainsKey(sessionId)) throw new VtpException("VTP2_SESSION_REPLAY");
        var seq=NeedLong(req,"recipient_bundle_sequence");
        string spkPrivate;
        if(seq==state.BundleSequence) spkPrivate=state.SignedPrekeyPrivate;
        else if(seq==state.PreviousBundleSequence && state.PreviousSignedPrekeyPrivate is not null) spkPrivate=state.PreviousSignedPrekeyPrivate;
        else throw new VtpException("VTP2_STALE_BUNDLE_SEQUENCE");
        var opkId=NeedString(req,"one_time_prekey_id"); if(!state.OneTimePrekeys.Remove(opkId,out var opkPrivate)) throw new VtpException("VTP2_OPK_CONSUMED_OR_UNKNOWN");
        var secret=ResponderSecret(state,spkPrivate,NeedString(req,"ephemeral_public_b64"),bundle,opkPrivate);
        var keys=DeriveInitial(secret,Transcript(req)); CryptographicOperations.ZeroMemory(secret);
        var peerId=NeedString(bundle,"device_id"); state.Sessions[sessionId]=NewSession(sessionId,peerId,Fingerprint(NeedString(bundle,"identity_sign_public_b64")),keys,false);
        var t=state.Trusted[peerId]; var initSeq=NeedLong(bundle,"sequence"); if(initSeq<t.LastBundleSequence) throw new VtpException("VTP2_BUNDLE_ROLLBACK"); t.LastBundleSequence=initSeq;
        StateStore.Save(statePath,state); Console.WriteLine("VTP2_SESSION_ACCEPT_OK:"+sessionId);
    }

    public static void Encrypt(Args a)
    {
        var statePath=a.Need("state"); var state=StateStore.Load(statePath); var session=NeedSession(state,a.Need("session"));
        var contentType=a.Get("content-type","application/octet-stream"); if(contentType.Length>128||contentType.Any(c=>c<0x20||c>0x7e)) throw new VtpException("VTP2_BAD_CONTENT_TYPE");
        var plain=SafeFile.Read(a.Need("in"),Protocol.MaxPlain); var messageId=RandomId(); var number=session.SendNumber;
        if(number==ulong.MaxValue) throw new VtpException("VTP2_COUNTER_EXHAUSTED");
        var chain=Unb64(session.SendChain); var (mk,next)=Advance(chain); CryptographicOperations.ZeroMemory(chain);
        var nonce=RandomNumberGenerator.GetBytes(12); var created=Now();
        var header=new JsonObject{{"schema","vtp.message.v2"},{"suite",Suite},{"session_id",session.SessionId},{"sender_device_id",state.DeviceId},{"recipient_device_id",session.PeerDeviceId},{"message_id",messageId},{"message_number",number},{"created_utc",created.ToString("O")},{"expires_utc",created.Add(Protocol.MessageLifetime).ToString("O")},{"content_type",contentType},{"nonce_b64",B64(nonce)},{"ciphertext_length",plain.Length}};
        var cipher=new byte[plain.Length]; var tag=new byte[16]; using(var c=new ChaCha20Poly1305(mk)) c.Encrypt(nonce,plain,cipher,tag,Canonical.Bytes(header));
        header["ciphertext_b64"]=B64(cipher); header["tag_b64"]=B64(tag);
        // The receiver refuses envelopes above MaxInput: never burn a message number on one.
        var envelopeBytes=Canonical.Bytes(header); if(envelopeBytes.Length>Protocol.MaxInput) throw new VtpException("VTP2_ENVELOPE_TOO_LARGE");
        // Reserve-and-commit: the advanced chain is durable before any ciphertext leaves.
        session.SendChain=B64(next); session.SendNumber++; StateStore.Save(statePath,state); SafeFile.WriteBytes(a.Need("out"),envelopeBytes);
        CryptographicOperations.ZeroMemory(mk); CryptographicOperations.ZeroMemory(next); CryptographicOperations.ZeroMemory(plain); Console.WriteLine("VTP2_ENCRYPT_OK:"+messageId);
    }

    public static void Decrypt(Args a)
    {
        var statePath=a.Need("state"); var state=StateStore.Load(statePath); var env=ReadObject(a.Need("in"));
        RequireExactFields(env,Protocol.MessageFields,"MESSAGE");
        Expect(env,"schema","vtp.message.v2"); Expect(env,"suite",Suite); var session=NeedSession(state,NeedString(env,"session_id"));
        if(NeedString(env,"sender_device_id")!=session.PeerDeviceId || NeedString(env,"recipient_device_id")!=state.DeviceId) throw new VtpException("VTP2_MESSAGE_BINDING_MISMATCH");
        var id=ValidateId(NeedString(env,"message_id"),"MESSAGE_ID"); if(session.SeenMessageIds.Contains(id,StringComparer.Ordinal)) throw new VtpException("VTP2_REPLAY_DETECTED");
        var created=ParseTime(NeedString(env,"created_utc")); var expires=ParseTime(NeedString(env,"expires_utc")); var now=Now();
        if(created>now.Add(Protocol.ClockSkew)) throw new VtpException("VTP2_MESSAGE_FROM_FUTURE"); if(expires<now) throw new VtpException("VTP2_MESSAGE_EXPIRED");
        if(expires-created>Protocol.MessageLifetime+Protocol.ClockSkew) throw new VtpException("VTP2_MESSAGE_LIFETIME_TOO_LONG");
        var n=NeedUlong(env,"message_number");
        if(n>session.ReceiveNumber && (n-session.ReceiveNumber>(ulong)Protocol.MaxSkippedKeys || (ulong)session.SkippedKeys.Count+(n-session.ReceiveNumber)>(ulong)Protocol.MaxSkippedKeys)) throw new VtpException("VTP2_SKIP_LIMIT");
        var cipher=Decode(NeedString(env,"ciphertext_b64"),Protocol.MaxPlain); if(NeedUlong(env,"ciphertext_length")!=(ulong)cipher.Length) throw new VtpException("VTP2_LENGTH_MISMATCH");
        var nonce=Decode(NeedString(env,"nonce_b64"),12); var tag=Decode(NeedString(env,"tag_b64"),16);
        byte[] messageKey; byte[]? nextChain=null;
        if(n<session.ReceiveNumber)
        {
            if(!session.SkippedKeys.Remove(n.ToString(),out var saved)) throw new VtpException("VTP2_REPLAY_OR_OLD_MESSAGE");
            messageKey=Unb64(saved);
        }
        else
        {
            var chain=Unb64(session.ReceiveChain);
            while(session.ReceiveNumber<n){var skipped=Advance(chain);CryptographicOperations.ZeroMemory(chain);chain=skipped.next;session.SkippedKeys[session.ReceiveNumber.ToString()]=B64(skipped.mk);session.ReceiveNumber++;}
            var current=Advance(chain); CryptographicOperations.ZeroMemory(chain); messageKey=current.mk; nextChain=current.next;
        }
        var aad=env.DeepClone().AsObject(); aad.Remove("ciphertext_b64"); aad.Remove("tag_b64");
        var plain=new byte[cipher.Length]; using(var c=new ChaCha20Poly1305(messageKey)) c.Decrypt(nonce,cipher,tag,plain,Canonical.Bytes(aad));
        if(nextChain is not null){session.ReceiveChain=B64(nextChain);session.ReceiveNumber++;CryptographicOperations.ZeroMemory(nextChain);}
        session.SeenMessageIds.Add(id); if(session.SeenMessageIds.Count>Protocol.ReplayJournal)session.SeenMessageIds.RemoveAt(0);
        // Replay state is committed before plaintext is released.
        StateStore.Save(statePath,state); SafeFile.WriteBytes(a.Need("out"),plain); CryptographicOperations.ZeroMemory(messageKey); CryptographicOperations.ZeroMemory(plain); Console.WriteLine("VTP2_DECRYPT_OK:"+id);
    }

    public static void Inspect(Args a) { var o=ReadObject(a.Need("in")); Console.WriteLine(NeedString(o,"schema")+":"+NeedString(o,"suite")); }

    public static void Status(Args a)
    {
        var s=StateStore.Load(a.Need("state"));
        Console.WriteLine("VTP2_STATUS_DEVICE:"+s.DeviceId);
        Console.WriteLine("VTP2_STATUS_BUNDLE_SEQUENCE:"+s.BundleSequence);
        Console.WriteLine("VTP2_STATUS_BUNDLE_EXPIRES_UTC:"+s.BundleExpiresUtc);
        Console.WriteLine("VTP2_STATUS_ONE_TIME_PREKEYS:"+s.OneTimePrekeys.Count);
        Console.WriteLine("VTP2_STATUS_TRUSTED_DEVICES:"+s.Trusted.Count);
        Console.WriteLine("VTP2_STATUS_SESSIONS:"+s.Sessions.Count);
        Console.WriteLine("VTP2_STATUS_OK");
    }

    // Known-answer tests for every primitive the protocol depends on (RFC 5869, RFC 4231,
    // RFC 8439), plus the protocol's own chain step, so a broken platform crypto provider
    // fails before any key is used.
    public static void KnownAnswerTests()
    {
        static void Check(string name,byte[] actual,string expectedHex){if(Convert.ToHexStringLower(actual)!=expectedHex)throw new VtpException("VTP2_KAT_FAIL:"+name);Console.WriteLine("VTP2_KAT_OK:"+name);}
        var hkdf=HKDF.DeriveKey(HashAlgorithmName.SHA256,Enumerable.Repeat((byte)0x0b,22).ToArray(),42,Convert.FromHexString("000102030405060708090a0b0c"),Convert.FromHexString("f0f1f2f3f4f5f6f7f8f9"));
        Check("HKDF_SHA256_RFC5869_TC1",hkdf,"3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865");
        using(var h=new HMACSHA256(Enumerable.Repeat((byte)0x0b,20).ToArray())) Check("HMAC_SHA256_RFC4231_TC1",h.ComputeHash("Hi There"u8.ToArray()),"b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7");
        var key=Convert.FromHexString("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f");
        var nonce=Convert.FromHexString("070000004041424344454647"); var aad=Convert.FromHexString("50515253c0c1c2c3c4c5c6c7");
        var pt="Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."u8.ToArray();
        var ct=new byte[pt.Length]; var tag=new byte[16]; using(var c=new ChaCha20Poly1305(key)) c.Encrypt(nonce,pt,ct,tag,aad);
        Check("CHACHA20POLY1305_RFC8439_2_8_2_TAG",tag,"1ae10b594f09e26a7e902ecbd0600691");
        Check("CHACHA20POLY1305_RFC8439_2_8_2_CT_PREFIX",ct[..16],"d31a8d34648e60db7b86afbc53ef7ec2");
        var back=new byte[ct.Length]; using(var c=new ChaCha20Poly1305(key)) c.Decrypt(nonce,ct,tag,back,aad); if(!back.SequenceEqual(pt)) throw new VtpException("VTP2_KAT_FAIL:CHACHA20POLY1305_ROUNDTRIP");
        var (mk,next)=Advance(new byte[32]);
        using(var h=new HMACSHA256(new byte[32])){ if(!mk.SequenceEqual(h.ComputeHash([1]))||!next.SequenceEqual(h.ComputeHash([2]))) throw new VtpException("VTP2_KAT_FAIL:CHAIN_STEP"); }
        Console.WriteLine("VTP2_KAT_OK:CHAIN_STEP");
        Console.WriteLine("VTP2_KAT_ALL_OK");
    }

    static void Replenish(DeviceState state)
    {
        while(state.OneTimePrekeys.Count<Protocol.OneTimePrekeyPool){using var k=ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256); state.OneTimePrekeys[RandomId()]=B64(k.ExportPkcs8PrivateKey());}
    }
    static JsonObject SignedBundle(DeviceState s)
    {
        var body=BundleBody(s);
        using var sign=LoadSign(s.SignPrivate);
        body["signature_b64"]=B64(sign.SignData(Canonical.Bytes(body),HashAlgorithmName.SHA256));
        return body;
    }
    static JsonObject BundleBody(DeviceState s)
    {
        using var sign=LoadSign(s.SignPrivate); using var dh=LoadDh(s.DhPrivate); using var spk=LoadDh(s.SignedPrekeyPrivate);
        var opks=new JsonArray(); foreach(var pair in s.OneTimePrekeys.OrderBy(x=>x.Key,StringComparer.Ordinal)){using var k=LoadDh(pair.Value);opks.Add(new JsonObject{{"id",pair.Key},{"public_b64",B64(k.ExportSubjectPublicKeyInfo())}});}
        return new JsonObject{{"schema","vtp.prekey_bundle.v2"},{"suite",Suite},{"device_id",s.DeviceId},{"sequence",s.BundleSequence},{"expires_utc",s.BundleExpiresUtc},{"identity_sign_public_b64",B64(sign.ExportSubjectPublicKeyInfo())},{"identity_dh_public_b64",B64(dh.ExportSubjectPublicKeyInfo())},{"signed_prekey_public_b64",B64(spk.ExportSubjectPublicKeyInfo())},{"one_time_prekeys",opks}};
    }
    static void ValidateBundle(JsonObject b)
    {
        RequireExactFields(b,Protocol.BundleFields,"BUNDLE");
        Expect(b,"schema","vtp.prekey_bundle.v2");Expect(b,"suite",Suite);ValidateId(NeedString(b,"device_id"),"DEVICE_ID");
        if(NeedLong(b,"sequence")<1) throw new VtpException("VTP2_BAD_BUNDLE_SEQUENCE");
        if(ParseTime(NeedString(b,"expires_utc"))<Now())throw new VtpException("VTP2_BUNDLE_EXPIRED");
        if(b["one_time_prekeys"] is not JsonArray opks) throw new VtpException("VTP2_BUNDLE_NO_OPK");
        foreach(var o in opks){ if(o is not JsonObject x) throw new VtpException("VTP2_BAD_OPK"); RequireExactFields(x,Protocol.OpkFields,"OPK"); }
        VerifySignedObject(b,NeedString(b,"identity_sign_public_b64"));
    }
    static void VerifySignedObject(JsonObject o,string pub){var clone=o.DeepClone().AsObject();var sig=Decode(NeedString(clone,"signature_b64"),256);clone.Remove("signature_b64");using var key=ECDsa.Create();key.ImportSubjectPublicKeyInfo(Unb64(pub),out _);if(key.KeySize!=256)throw new VtpException("VTP2_BAD_KEY");if(!key.VerifyData(Canonical.Bytes(clone),sig,HashAlgorithmName.SHA256))throw new VtpException("VTP2_BAD_SIGNATURE");}
    static void RequireTrusted(DeviceState s,JsonObject b){var id=NeedString(b,"device_id");var fp=Fingerprint(NeedString(b,"identity_sign_public_b64"));if(!s.Trusted.TryGetValue(id,out var t)||t.Fingerprint!=fp)throw new VtpException("VTP2_UNTRUSTED_IDENTITY");if(t.SignPublic!=NeedString(b,"identity_sign_public_b64")||t.DhPublic!=NeedString(b,"identity_dh_public_b64"))throw new VtpException("VTP2_TRUSTED_KEY_MISMATCH");}
    static byte[] InitiatorSecret(DeviceState s,ECDiffieHellman eph,JsonObject b,string opk){using var id=LoadDh(s.DhPrivate);return Join(Agree(id,NeedString(b,"signed_prekey_public_b64")),Agree(eph,NeedString(b,"identity_dh_public_b64")),Agree(eph,NeedString(b,"signed_prekey_public_b64")),Agree(eph,opk));}
    static byte[] ResponderSecret(DeviceState s,string spkPrivate,string ephPub,JsonObject b,string opkPriv){using var spk=LoadDh(spkPrivate);using var id=LoadDh(s.DhPrivate);using var opk=LoadDh(opkPriv);return Join(Agree(spk,NeedString(b,"identity_dh_public_b64")),Agree(id,ephPub),Agree(spk,ephPub),Agree(opk,ephPub));}
    static byte[] Agree(ECDiffieHellman own,string peer){using var p=ECDiffieHellman.Create();p.ImportSubjectPublicKeyInfo(Unb64(peer),out _);if(p.KeySize!=256)throw new VtpException("VTP2_BAD_KEY");return own.DeriveKeyFromHash(p.PublicKey,HashAlgorithmName.SHA256);}
    // Transcript hash over the signed handshake body without its signature: ECDSA signatures are
    // malleable, so binding keys to the signature bytes would let a relay break sessions.
    static byte[] Transcript(JsonObject signedBody){var c=signedBody.DeepClone().AsObject();c.Remove("signature_b64");return Canonical.Hash(c);}
    static (byte[] root,byte[] i2r,byte[] r2i) DeriveInitial(byte[] secret,byte[] transcript){var x=Hkdf(secret,transcript,"VTP2 initial session",96);return(x[..32],x[32..64],x[64..96]);}
    static SessionState NewSession(string id,string peer,string fp,(byte[] root,byte[] i2r,byte[] r2i) k,bool initiator)=>new(){SessionId=id,PeerDeviceId=peer,PeerFingerprint=fp,RootKey=B64(k.root),SendChain=B64(initiator?k.i2r:k.r2i),ReceiveChain=B64(initiator?k.r2i:k.i2r)};
    static SessionState NeedSession(DeviceState s,string id)=>s.Sessions.TryGetValue(id,out var x)?x:throw new VtpException("VTP2_UNKNOWN_SESSION");
    static (byte[] mk,byte[] next) Advance(byte[] chain){using var h1=new HMACSHA256(chain);var mk=h1.ComputeHash([1]);using var h2=new HMACSHA256(chain);return(mk,h2.ComputeHash([2]));}
    static byte[] Hkdf(byte[] ikm,byte[] salt,string info,int len)=>HKDF.DeriveKey(HashAlgorithmName.SHA256,ikm,len,salt,Encoding.UTF8.GetBytes(info));
    static ECDsa LoadSign(string b){var x=ECDsa.Create();x.ImportPkcs8PrivateKey(Unb64(b),out _);return x;} static ECDiffieHellman LoadDh(string b){var x=ECDiffieHellman.Create();x.ImportPkcs8PrivateKey(Unb64(b),out _);return x;}
    static JsonObject ReadObject(string p)=>StrictJson.ParseObject(SafeFile.Read(p,Protocol.MaxInput));
    static void RequireExactFields(JsonObject o,string[] allowed,string label){foreach(var p in o){if(!allowed.Contains(p.Key,StringComparer.Ordinal))throw new VtpException("VTP2_UNKNOWN_FIELD:"+label+":"+p.Key);}}
    static string NeedString(JsonObject o,string n)=>o[n] is JsonValue v && v.TryGetValue<string>(out var x) && !string.IsNullOrWhiteSpace(x)?x:throw new VtpException("VTP2_MISSING_FIELD:"+n);
    static ulong NeedUlong(JsonObject o,string n)=>o[n] is JsonValue v && v.TryGetValue<ulong>(out var x)?x:throw new VtpException("VTP2_MISSING_FIELD:"+n);
    static long NeedLong(JsonObject o,string n)=>o[n] is JsonValue v && v.TryGetValue<long>(out var x)?x:throw new VtpException("VTP2_MISSING_FIELD:"+n);
    static void Expect(JsonObject o,string n,string v){if(NeedString(o,n)!=v)throw new VtpException("VTP2_UNSUPPORTED_"+n.ToUpperInvariant());}
    static string ValidateId(string x,string label){if(x.Length is < 8 or > 80 || x.Any(c=>!(char.IsAsciiLetterOrDigit(c)||c is '-' or '_' or '.')))throw new VtpException("VTP2_BAD_"+label);return x;}
    static DateTimeOffset Now()=>DateTimeOffset.UtcNow;
    static string RandomId()=>Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16)); static string B64(byte[] x)=>Convert.ToBase64String(x); static byte[] Unb64(string x){try{return Convert.FromBase64String(x);}catch(FormatException){throw new VtpException("VTP2_BAD_BASE64");}}
    static byte[] Decode(string x,int exactOrMax){var b=Unb64(x);if(exactOrMax<=32?b.Length!=exactOrMax:b.Length>exactOrMax)throw new VtpException("VTP2_BAD_BINARY_LENGTH");return b;}
    static string Fingerprint(string pub)=>Convert.ToHexStringLower(SHA256.HashData(Unb64(pub))); static byte[] Join(params byte[][] xs){var r=new byte[xs.Sum(x=>x.Length)];var n=0;foreach(var x in xs){x.CopyTo(r,n);n+=x.Length;CryptographicOperations.ZeroMemory(x);}return r;}
    static DateTimeOffset ParseTime(string x)=>DateTimeOffset.TryParseExact(x,"O",System.Globalization.CultureInfo.InvariantCulture,System.Globalization.DateTimeStyles.RoundtripKind,out var t)?t:throw new VtpException("VTP2_BAD_TIME");
}

// Strict decoder: rejects duplicate keys at any depth, depth > 16, comments and trailing
// commas, before any value is interpreted.
static class StrictJson
{
    public static JsonObject ParseObject(byte[] utf8)
    {
        var reader=new Utf8JsonReader(utf8,new JsonReaderOptions{MaxDepth=16,AllowTrailingCommas=false,CommentHandling=JsonCommentHandling.Disallow});
        var scopes=new Stack<HashSet<string>?>();
        while(reader.Read())
        {
            switch(reader.TokenType)
            {
                case JsonTokenType.StartObject: scopes.Push(new HashSet<string>(StringComparer.Ordinal)); break;
                case JsonTokenType.StartArray: scopes.Push(null); break;
                case JsonTokenType.EndObject: case JsonTokenType.EndArray: scopes.Pop(); break;
                case JsonTokenType.PropertyName:
                    if(!scopes.Peek()!.Add(reader.GetString()!)) throw new VtpException("VTP2_DUPLICATE_KEY");
                    break;
            }
        }
        var node=JsonNode.Parse(utf8,new JsonNodeOptions{PropertyNameCaseInsensitive=false},new JsonDocumentOptions{MaxDepth=16,AllowTrailingCommas=false,CommentHandling=JsonCommentHandling.Disallow});
        return node as JsonObject ?? throw new VtpException("VTP2_INVALID_JSON");
    }
}

static class Canonical
{
    // Minimal escaping (quote, backslash, control characters only). The default encoder would turn
    // every '+' of base64 into \u002B, inflating envelopes by up to 6x per character.
    static readonly JsonSerializerOptions Options=new(){WriteIndented=false,Encoder=System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping};
    public static byte[] Bytes(JsonNode node)=>JsonSerializer.SerializeToUtf8Bytes(Sort(node),Options);
    public static byte[] Hash(JsonNode node)=>SHA256.HashData(Bytes(node));
    static JsonNode? Sort(JsonNode? n){if(n is JsonObject o){var r=new JsonObject();foreach(var p in o.OrderBy(x=>x.Key,StringComparer.Ordinal))r[p.Key]=Sort(p.Value);return r;}if(n is JsonArray a){var r=new JsonArray();foreach(var x in a)r.Add(Sort(x));return r;}return n?.DeepClone();}
}

static class StateStore
{
    public static IDisposable Lock(string statePath)
    {
        var path=Path.GetFullPath(statePath)+".lock"; Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var until=DateTime.UtcNow.AddSeconds(30);
        do{try{return new FileStream(path,FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None);}catch(IOException){Thread.Sleep(25);}}while(DateTime.UtcNow<until);
        throw new VtpException("VTP2_STATE_BUSY");
    }
    public static DeviceState Load(string path)
    {
        var data=SafeFile.Read(Path.GetFullPath(path),Protocol.MaxInput*8);
        var raw=StateProtection.Unprotect(data);
        try{return JsonSerializer.Deserialize<DeviceState>(raw)??throw new VtpException("VTP2_STATE_CORRUPT");}
        catch(JsonException){throw new VtpException("VTP2_STATE_CORRUPT");}
        finally{CryptographicOperations.ZeroMemory(raw);}
    }
    public static void Save(string path,DeviceState s){var raw=JsonSerializer.SerializeToUtf8Bytes(s);try{SafeFile.WriteBytes(path,StateProtection.Protect(raw),ownerOnly:true);}finally{CryptographicOperations.ZeroMemory(raw);}}
}

static class SafeFile
{
    public static byte[] Read(string path,int max){var f=new FileInfo(Path.GetFullPath(path));if(!f.Exists)throw new VtpException("VTP2_FILE_NOT_FOUND");if(f.Length>max)throw new VtpException("VTP2_INPUT_TOO_LARGE");return File.ReadAllBytes(f.FullName);}
    public static void WriteJson(string path,JsonObject o)=>WriteBytes(path,Canonical.Bytes(o));
    public static void WriteBytes(string path,byte[] data,bool ownerOnly=false)
    {
        path=Path.GetFullPath(path);Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var tmp=path+"."+Guid.NewGuid().ToString("N")+".tmp";
        var options=new FileStreamOptions{Mode=FileMode.CreateNew,Access=FileAccess.Write,Share=FileShare.None};
        if(ownerOnly && !OperatingSystem.IsWindows()) options.UnixCreateMode=UnixFileMode.UserRead|UnixFileMode.UserWrite;
        using(var f=new FileStream(tmp,options)){f.Write(data);f.Flush(true);}
        File.Move(tmp,path,true);
    }
}

// Windows: DPAPI CurrentUser. Elsewhere there is no OS keystore this tool can rely on, so the
// state is sealed with ChaCha20-Poly1305 under a 32-byte key the operator provides through the
// VTP2_STATE_KEY_FILE environment variable (owner-only permissions required). Without it the
// tool refuses to read or write state; there is no plaintext fallback.
static class StateProtection
{
    static readonly byte[] Magic = "VTP2SK1\0"u8.ToArray();
    public static byte[] Protect(byte[] x)
    {
        if(OperatingSystem.IsWindows()) return Dpapi.Protect(x);
        var key=KeyFile(); try{
            var nonce=RandomNumberGenerator.GetBytes(12); var cipher=new byte[x.Length]; var tag=new byte[16];
            using(var c=new ChaCha20Poly1305(key)) c.Encrypt(nonce,x,cipher,tag,Magic);
            return [..Magic,..nonce,..tag,..cipher];
        } finally { CryptographicOperations.ZeroMemory(key); }
    }
    public static byte[] Unprotect(byte[] x)
    {
        if(OperatingSystem.IsWindows()) return Dpapi.Unprotect(x);
        var key=KeyFile(); try{
            if(x.Length<Magic.Length+28 || !x.AsSpan(0,Magic.Length).SequenceEqual(Magic)) throw new VtpException("VTP2_STATE_PROTECTION_FAILED");
            var nonce=x.AsSpan(Magic.Length,12); var tag=x.AsSpan(Magic.Length+12,16); var cipher=x.AsSpan(Magic.Length+28);
            var plain=new byte[cipher.Length];
            try{using var c=new ChaCha20Poly1305(key); c.Decrypt(nonce,cipher,tag,plain,Magic);}
            catch(CryptographicException){throw new VtpException("VTP2_STATE_PROTECTION_FAILED");}
            return plain;
        } finally { CryptographicOperations.ZeroMemory(key); }
    }
    static byte[] KeyFile()
    {
        var p=Environment.GetEnvironmentVariable("VTP2_STATE_KEY_FILE");
        if(string.IsNullOrWhiteSpace(p)) throw new VtpException("VTP2_STATE_KEY_REQUIRED");
        var f=new FileInfo(p); if(!f.Exists) throw new VtpException("VTP2_STATE_KEY_MISSING");
        if(!OperatingSystem.IsWindows() && (File.GetUnixFileMode(f.FullName) & (UnixFileMode.GroupRead|UnixFileMode.GroupWrite|UnixFileMode.OtherRead|UnixFileMode.OtherWrite))!=0)
            throw new VtpException("VTP2_STATE_KEY_PERMISSIONS_TOO_OPEN");
        var k=File.ReadAllBytes(f.FullName); if(k.Length!=32){CryptographicOperations.ZeroMemory(k);throw new VtpException("VTP2_STATE_KEY_BAD_LENGTH");}
        return k;
    }
}

static class Dpapi
{
    [StructLayout(LayoutKind.Sequential)] struct Blob{public int Length;public IntPtr Data;}
    [DllImport("crypt32.dll",SetLastError=true,CharSet=CharSet.Unicode)] static extern bool CryptProtectData(ref Blob input,string? description,IntPtr entropy,IntPtr reserved,IntPtr prompt,uint flags,out Blob output);
    [DllImport("crypt32.dll",SetLastError=true)] static extern bool CryptUnprotectData(ref Blob input,IntPtr description,IntPtr entropy,IntPtr reserved,IntPtr prompt,uint flags,out Blob output);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr hMem);
    public static byte[] Protect(byte[] x)=>Run(x,true); public static byte[] Unprotect(byte[] x)=>Run(x,false);
    static byte[] Run(byte[] x,bool protect){var p=Marshal.AllocHGlobal(x.Length);Marshal.Copy(x,0,p,x.Length);var input=new Blob{Length=x.Length,Data=p};try{Blob output;var ok=protect?CryptProtectData(ref input,"VTP2 protected state",IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,1,out output):CryptUnprotectData(ref input,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,1,out output);if(!ok)throw new VtpException("VTP2_STATE_PROTECTION_FAILED");try{var r=new byte[output.Length];Marshal.Copy(output.Data,r,0,r.Length);return r;}finally{LocalFree(output.Data);}}finally{Marshal.FreeHGlobal(p);}}
}
