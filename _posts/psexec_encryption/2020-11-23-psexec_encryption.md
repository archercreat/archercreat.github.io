---
title: Поиск иголки в стоге сена или как PsExec шифрует трафик
date: 2021-04-18 21:04:00 +07:00
tags: [Windows Internals]
image: /assets/img/posts/psexec_encryption/TA8yqVA.png
---

![](/assets/img/posts/psexec_encryption/TA8yqVA.png)

В марте 2014 года у популярной утилиты для администрирования появилась возможность шифрования трафика. К сожалению или к счастью, это единственная информация о том, как PsExec шифрует трафик. Под катом мы заглянем во внутренности PsExec и OS Windows и узнаем что происходит на самом деле. Конечная цель этого поста - понять как можно расшифровать перехваченный `PsExec` трафик.

# PsExec

Данное программное обеспечения поставляется с пакетом программ `Sysinternals Suite` и позволяет системным администраторам выполнять команды на удаленных компьютерах. 

Визитной карточкой `PsExec` служит `PSEXESVC` сервис, который запускается на удаленном пк и выполняет команды клиента.

![](/assets/img/posts/psexec_encryption/KB7atKR.png)

Если на удаленном хосте не установлена служба `psexecsvc.exe`, то экземпляр передается по сети и устанавливается в `%SystemRoot%`.

Коммуникация с сервисом происходит с помощью пайпов:

![](/assets/img/posts/psexec_encryption/Azkfc9Y.png)

# Шифрование

Для шифрования трафика PsExec использует `CryptEncrypt` и `CryptDecrypt` API. Как говорил Марк в своем твите, если ОС Windows XP или Windows Server 2003 - для обмена ключами шифрования используется алгоритм Диффи-Хеллмана. 

В остальных случаях ключ генерируется следующим образом:

![](/assets/img/posts/psexec_encryption/Uru4yH6.png)

К 16 неизвестным байт добавляется строчка `Sysinternals Rocks` и хэшируется `SHA1`. Этот хэш используется как AES_256 ключ для последующего шифрования.

# NtFsControlFile

Чтобы получить 16 неизвестных байт, PsExec открывает "файл" `\\Device\\LanmanRedirector\\{device}\\ipc$`, где device - Адрес удаленного хоста.

![](/assets/img/posts/psexec_encryption/d0eA0DL.png)

После чего с помощью `NtFsControlFile` IOCTL кода `0x1401a3` заполняется 16 неизвестных байт из `output` буффера.

![](/assets/img/posts/psexec_encryption/S8GOqLo.png)

К сожалению, информации по данному IOCTL в открытом доступе я не нашел, поэтому решил заглянуть в слитые исходники Windows XP. 

Для начала поймем какой номер функции используется в IOCTL:

```bash
python .\ioctl.py 0x1401a3
[*] Device Type: FILE_DEVICE_NETWORK_FILE_SYSTEM
[*] Function Code: 0x68
[*] Access Check: FILE_ANY_ACCESS
[*] I/O Method: METHOD_NEITHER
[*] CTL_CODE(FILE_DEVICE_NETWORK_FILE_SYSTEM, 0x68, METHOD_NEITHER, FILE_ANY_ACCESS)
```

`grep` кода функции по исходникам Windows XP выдал следующий результат:
```bash
grep -r "104, METHOD_NEITHER, FILE_ANY_ACCESS" | grep define
sdk/inc/ntddnfs.h:#define FSCTL_LMR_GET_CONNECTION_INFO    _RDR_CONTROL_CODE(104, METHOD_NEITHER, FILE_ANY_ACCESS)
```

Поиск по `FSCTL_LMR_GET_CONNECTION_INFO` привел в функцию
`base\fs\rdr2\rdbss\smb.mrx\fsctl.c#L1737`:

```c++
else if (FsControlCode == FSCTL_LMR_GET_CONNECTION_INFO)
{
    PSMBCEDB_SERVER_ENTRY pServerEntry = SmbCeGetAssociatedServerEntry(capFcb->pNetRoot->pSrvCall);
    Status = STATUS_INVALID_PARAMETER;
    pOutputDataBuffer       = pLowIoContext->ParamsFor.FsCtl.pOutputBuffer;
    OutputDataBufferLength  = pLowIoContext->ParamsFor.FsCtl.OutputBufferLength;
    if (pOutputDataBuffer && (OutputDataBufferLength==sizeof(LMR_CONNECTION_INFO_3)))
    {
        try
        {
            ProbeForWrite(
                pOutputDataBuffer,
                OutputDataBufferLength,
                1);
            if (!memcmp(pOutputDataBuffer,EA_NAME_CSCAGENT,sizeof(EA_NAME_CSCAGENT)))
            {
                MRxSmbGetConnectInfoLevel3Fields(
                    (PLMR_CONNECTION_INFO_3)(pOutputDataBuffer),
                    pServerEntry,
                    TRUE);
                Status = STATUS_SUCCESS;
            }
        }
```
Здесь `pOutputDataBuffer` используется как структура `PLMR_CONNECTION_INFO_3`. На `0x2c` оффесете которой как раз находится `UserSessionKey` размером 16 байт.
```c++
typedef struct _LMR_CONNECTION_INFO_3_32 {
    UNICODE_STRING_32 UNCName;          // Name of UNC connection
    ULONG ResumeKey;                    // Resume key for this entry.
    DEVICE_TYPE SharedResourceType;     // Type of shared resource
    ULONG ConnectionStatus;             // Status of the connection
    ULONG NumberFilesOpen;              // Number of opened files

    UNICODE_STRING_32 UserName;         // User who created connection.
    UNICODE_STRING_32 DomainName;       // Domain of user who created connection.
    ULONG Capabilities;                 // Bit mask of remote abilities.
    UCHAR UserSessionKey[MSV1_0_USER_SESSION_KEY_LENGTH]; // User session key
    UCHAR LanmanSessionKey[MSV1_0_LANMAN_SESSION_KEY_LENGTH]; // Lanman session key
    UNICODE_STRING_32 TransportName;    // Transport connection is active on
    ...
```

Следовательно те неизвестные 16 байт - сессионный ключ, который создается при NTLMv2 аутентификации.

# NTLMv2 и ключ сессии

NTLMv2 — встроенный в операционные системы семейства Microsoft Windows протокол сетевой аутентификации. Широко применяется в различных сервисах на их базе. Изначально был предназначен для повышения безопасности аутентификации путём замены устаревших LM и NTLM v1. NTLMv2 был введён начиная с Windows NT 4.0 SP4 и используется версиями Microsoft Windows вплоть до Windows 10 включительно.

В схеме аутентификации, реализованной при помощи SMB или SMB2 сообщений, вне зависимости от того, какой вид диалекта аутентификации будет использован, процесс аутентификации происходит следующим образом:

1. Клиент пытается установить соединение с сервером и посылает запрос, в котором информирует сервер, на каких диалектах он способен произвести аутентификации.
2. Сервер из полученного от клиента списка диалектов (по умолчанию) выбирает наиболее защищённый диалект (например, NTLMv2), затем отправляет ответ клиенту.
3. Клиент, определившись с диалектом аутентификации, пытается получить доступ к серверу и посылает запрос NEGOTIATE_MESSAGE.
4. Сервер получает запрос от клиента и посылает ему ответ CHALLENGE_MESSAGE, в котором содержится случайная (random) последовательность из 8 байт. Она называется Server Challenge.
5. Клиент, получив от сервера последовательность Server Challenge, при помощи своего пароля производит шифрование этой последовательности, а затем посылает серверу ответ AUTHENTICATE_MESSAGE, который содержит 24 байта.
6. Сервер, получив ответ, производит ту же операцию шифрования последовательности Server Challenge, которую произвёл клиент. Затем, сравнив свои результаты с ответом от клиента, на основании совпадения разрешает или запрещает доступ.

В трафике это выглядит следующим образом:

![](/assets/img/posts/psexec_encryption/ZtpyKWm.png)

Алгоритм создания ключа сессии:
1. Вычисляется `NTLM_hash = MD4(password)`
2. Вычисляется `NTLMv2_hash = hmac_md5(NTLM_hash, username.upper()+domain)`
3. Вычисляется `NtProofStr = hmac_md5(NTLMv2_hash, server_challenge + blob)`
4. Вычисляется `session_key = hmac_md5(NTLMv2_hash, NtProofStr)`


Если же был выбран `Negotiate key exchange`, то `session_key` превращается в RC4 ключ для шифрования рандомной 16 байтовой последовательности, которая потом и передается в трафике как `session_key`.

Следовательно чтобы расшифровать трафик PsExec необходимо иметь пароль пользователя и 3 пакета `NTLMSSP_AUTH`, верно? Не совсем.

Как оказалось, сессионный ключ, который вычисляется при NTLMv2 аутентификации и сессионный ключ, который получает PsExec с помощью `NtFsControlFile` не совпадают.

# Ищем иголку в стоге сена

Сначала я думал, что я неправильно вычисляю NTLMv2 сессионный ключ. Чтобы проверить это, я решил написать библиотеку, которая будет перехватывать NTLM функции и выписывать нужные мне значения. 
Как известно, за аутентификацию в системе отвечает процесс `lsass.exe`.

![](/assets/img/posts/psexec_encryption/YudRGI9.png)

В частности, за NTLM отвечают библиотеки `msv1_0.dll` и `NtlmShared.dll`.

Чтобы понять, какие функции мне нужно перехватить, я использовал `frida-trace`:

```bash
> frida-trace lsass.exe -I NtlmShared.dll

           /* TID 0x850 */
 13818 ms  NtLmAlterRtlEqualUnicodeString()
 13818 ms  NtLmAlterRtlEqualUnicodeString()
 13818 ms  NtLmAlterRtlEqualUnicodeString()
 13818 ms  MsvpPutClearOwfsInPrimaryCredential()
 13818 ms  MsvpLm20GetNtlm3ChallengeResponse()
 13818 ms     | MsvpNtlm3Response()
 13818 ms     |    | MsvpCalculateNtlm3Owf()
```

Три функции бросаются в глаза:
```
MsvpLM20GetNtlm3ChallengeResponse - Вычисляет NTLM_response, LM_response
MsvpNtlm3Response                 - Вычисляет UserSessionKey, NtProofStr
MsvpCalculateNtlm3Owf             - Вычисляет NTLMv2_hash
```

Так же функция `SsprMakeSessionKey` в `msv1_0.dll` используется для создания сессионного ключа и `RC4` шифрования.

Перехватив эти функции получаем следущее:
```
[+] Panda online
[*] Setting up hooks
[+] 0x00007ffd07d70000	msv1_0.dll
[+] 0x00007ffd07d50000	NtlmShared.dll
[*] Hooking 0x00007ffd07dd0a10
[*] Hooking 0x00007ffd07d518c0
[*] Hooking 0x00007ffd07d51c30
[*] Hooking 0x00007ffd07dcb470
[+] Done setting up hooks
[*] Called LM20GetNtlm3ChallengeResponse
	UserPassword: Administratork5y4m8d2
	Domain: DESKTOP-5SNDDCH
[*] Called MsvpNtlm3Response
	NTLM Hash: d110843d880486c2e9eb8cae52a3f7e5
	UserPassword: Administratork5y4m8d2
	Domain: DESKTOP-5SNDDCH
	ServerChallenge: 14aa123977e1bbb9
[*] Called MsvpCalculateNtlm3Owf
	NTLM Hash: d110843d880486c2e9eb8cae52a3f7e5
	UserPassword: Administratork5y4m8d2
	Domain: DESKTOP-5SNDDCH
	NTLMv2 Hash: 9755854f7b92eb35dc4dd4021ecab92b
[*] Return MsvpCalculateNtlm3Owf
	UserSessionKey: 980b87df588aff63810cdc3ca1e19ea5
	LmSessionKey: 980b87df588aff631200000000000000
	NtProofStr: 2047ba24f0b3d6d69ef8bfc73dcfbe78
[*] Return MsvpNtlm3Response
	SessionKey: 980b87df588aff63810cdc3ca1e19ea5
	LM Response:
		ClientChallenge: 0000000000000000
		Response: 00000000000000000000000000000000
	NTLM Response:
		ClientChallenge: 7406b827e31472d9
		TimeStamp: 0x1d7345390ec3462
		NtProofStr: 2047ba24f0b3d6d69ef8bfc73dcfbe78
[*] Return LM20GetNtlm3ChallengeResponse
[*] Called SsprMakeSessionKey
	UserSessionKey: 980b87df588aff63810cdc3ca1e19ea5
	LanmanSessionKey: 980b87df588aff63
	DatagramSessionKey before call: 00000000000000000000000000000000
        ContextSessionKey before call: cec7c38bc5650ebff207947d8996eaa1
	DatagramSessionKey after call: 333924f59319745239e4f0d3eafcaba7
        ContextSessionKey after call: cec7c38bc5650ebff207947d8996eaa1
[*] Return SsprMakeSessionKey
[+] Exiting..
```

На выходе `ContextSessionKey` `cec7c38bc5650ebff207947d8996eaa1` - расшифрованный сессионый ключ, `DatagramSessionKey` `333924f59319745239e4f0d3eafcaba7` его RC4 зашифрованная версия, но при этом PsExec получает `a082f9980639311e0422545662243274` ключ. Значит дело не в lsass и нужно копать глубже.

# Идем в ядро

За SMB и SMB2 соединение отвечают 2 драйвера - `mrxsmb.sys` и `mrxsmb20.sys` соответственно. 
Драйвер `mrxsmb20.sys` использует `mrxsmb.sys` как библиотеку для NTLM криптографии и работу с SMB протоколом.

Поскольку над сессионным ключом явно происходят какие-то действия, я решил перехватывать все крипто функции.

```
0: kd> x mrxsmb!SmbCrypto*
fffff800`65217d78 mrxsmb!SmbCryptoCreateCipherKeys (void)
fffff800`652033c8 mrxsmb!SmbCryptoSp800108CtrHmacSha256DeriveKey (void)
fffff800`652058f0 mrxsmb!SmbCryptoKeyTableRemove (void)
fffff800`65217ac8 mrxsmb!SmbCryptoKeyTableInsert (void)
fffff800`65264b5c mrxsmb!SmbCryptoInitialize (void)
fffff800`6525f720 mrxsmb!SmbCryptoHashCreate (void)
fffff800`65264980 mrxsmb!SmbCryptoReadCipherSuiteOrderPolicySetting (void)
fffff800`65203e70 mrxsmb!SmbCryptoUpdatePreauthIntegrityHashValue (SmbCryptoUpdatePreauthIntegrityHashValue)
fffff800`6525d1e0 mrxsmb!SmbCryptoCiphers = <no type information>
fffff800`65219380 mrxsmb!SmbCryptoCreateApplicationKey (SmbCryptoCreateApplicationKey)
fffff800`6526ac4c mrxsmb!SmbCryptoDeinitialize (SmbCryptoDeinitialize)
fffff800`65204bb0 mrxsmb!SmbCryptoKeyTableReferenceObject (SmbCryptoKeyTableReferenceObject)
fffff800`65262240 mrxsmb!SmbCryptoHashAlgorithmInitialize (SmbCryptoHashAlgorithmInitialize)
fffff800`65203350 mrxsmb!SmbCryptoCreateSigningKey (SmbCryptoCreateSigningKey)
fffff800`6525fb20 mrxsmb!SmbCryptoHashDestroy (SmbCryptoHashDestroy)
fffff800`65233da0 mrxsmb!SmbCryptoKeyTableCleanupObject (SmbCryptoKeyTableCleanupObject)
fffff800`6525d200 mrxsmb!SmbCryptoHashAlgorithms = <no type information>
fffff800`652049e0 mrxsmb!SmbCryptoKeyTableCompareHashKeys (SmbCryptoKeyTableCompareHashKeys)
fffff800`6523ab90 mrxsmb!SmbCryptoEncrypt (SmbCryptoEncrypt)
fffff800`6525d1c0 mrxsmb!SmbCryptoSp800108CtrHmacAlgHandle = <no type information>
fffff800`6523aaa4 mrxsmb!SmbCryptoDecrypt (SmbCryptoDecrypt)
fffff800`65217c88 mrxsmb!SmbCryptoCreateClientCipherKeys (SmbCryptoCreateClientCipherKeys)
fffff800`6525d060 mrxsmb!SmbCryptoNonceCounter = <no type information>
fffff800`65204a10 mrxsmb!SmbCryptoHashGetOutputLength (SmbCryptoHashGetOutputLength)
```

Для этого был написан WinDbg скрипт, который трейсил и логировал вызовы функций. 
Из всего списка перехваченных функций меня привлекла `SmbCryptoCreateCipherKeys`. Она вызывалась одной из первых и только 1 раз.

![](/assets/img/posts/psexec_encryption/HYCtUza.png)

Эта функция имеет только 1 xref с очень интересным названием, а 2-ым аргументом передается 16 байтовый ключ. 

Выпишем этот ключ с помощью WinDbg скрипта:

```javascript
 /// <reference path="JSProvider.d.ts" />
"use strict";

const log  = x => host.diagnostics.debugLog(x+'\n');
const ok   = x => log(`[+] ${x}`);
const warn = x => log(`[!] ${x}`);
const err  = x => log(`[-] ${x}`);

const  u8 = x => host.memory.readMemoryValues(x, 1, 1)[0];
const u16 = x => host.memory.readMemoryValues(x, 1, 2)[0];
const u32 = x => host.memory.readMemoryValues(x, 1, 4)[0];
const u64 = x => host.memory.readMemoryValues(x, 1, 8)[0];

const mem_read_array   = (x, y) => host.memory.readMemoryValues(x, y);
const mem_read_string  = x => host.memory.readString(x);
const mem_read_wstring = x => host.memory.readWideString(x);

function hex(arr) {
    return Array.from(arr, function(byte) {
      return ('0' + (byte & 0xFF).toString(16)).slice(-2);
    }).join('')
}

function handle_create_cipher_keys() {
    ok('mrxsmb!SmbCryptoCreateCipherKeys hit!');
    let regs = host.currentThread.Registers.User;
    let args = [regs.rcx, regs.rdx, regs.r8, regs.r9];
    let secret = mem_read_array(args[1], 16);
    let method = mem_read_string(args[3]);
    ok('Method: ' + method + ', Secret: ' + hex(secret));
}

function invokeScript() {
    let control = host.namespace.Debugger.Utility.Control;
    // Hook SmbCryptoCreateCipherKeys
    let bp_1 = control.SetBreakpointAtOffset("SmbCryptoCreateCipherKeys", 0, "mrxsmb");
    bp_1.Command = 'dx @$scriptContents.handle_create_cipher_keys(); gc';
    ok('Press "g" to run the target.');
}
```

Получаем:

```
[+] mrxsmb!SmbCryptoCreateCipherKeys hit!
[+] Method: SMBC2SCipherKey, Secret: cec7c38bc5650ebff207947d8996eaa1
@$scriptContents.handle_create_cipher_keys()
```

И что мы видим, это наш расшифрованный сессионный ключ!

Дальше я потрейсил где вызывается эта функция. Стэк вызовов получился следующим:

```
1: kd> k
 # Child-SP          RetAddr               Call Site
00 ffffd98e`0e95d378 fffff800`65217d56     mrxsmb!SmbCryptoCreateCipherKeys
01 ffffd98e`0e95d380 fffff800`65261fdd     mrxsmb!SmbCryptoCreateClientCipherKeys+0xce
02 ffffd98e`0e95d400 fffff800`65217aa3     mrxsmb!RxCeCreateAndRegisterCryptoKeys+0x7d
03 ffffd98e`0e95d480 fffff800`652a51a1     mrxsmb!VctCreateAndRegisterCryptoKeys+0x43
04 ffffd98e`0e95d4d0 fffff800`652dbfbf     mrxsmb20!ValidateSessionSetupSecurityBlob+0x435
05 ffffd98e`0e95d620 fffff800`6520696e     mrxsmb20!Smb2SessionSetup_Finalize+0xdf
06 ffffd98e`0e95daa0 fffff800`6520688d     mrxsmb!SmbCepFinalizeExchange+0x7a
07 ffffd98e`0e95dae0 fffff800`64d554b2     mrxsmb!SmbCepFinalizeExchangeWorker+0x4d
```

Как видно, mrxsmb20 вызывает эту функцию в последней стадии установки сессии с удаленным хостом.

В `mrxsmb20!ValidateSessionSetupSecurityBlob`, которая передает сессионный ключ далее по стэку можно заметить, что он используется еще в одной функции ниже.

![](/assets/img/posts/psexec_encryption/33MHgAl.png)

Сама Smb2DeriveApplicationKey:

![](/assets/img/posts/psexec_encryption/J8nMJQ3.png)

То есть если версия диалекта (SMB протокола) >= 3.0, создается ApplicationKey, который перезаписывает UserSessionKey.
Если же нет, UserSessionKey не изменяется.

![](/assets/img/posts/psexec_encryption/7fKYBeU.png)

`SmbCryptoCreateApplicationKey` - обертка над `SP800-108 hmac SHA256`, где в качестве ключа - используется наш сессионный ключ.

Попробуем перехватить ApplicationKey сразу после вызова `SmbCryptoSp800108CtrHmacSha256DeriveKey` и залогировать его:

```javascript
...

function handle_create_application_key() {
    ok('mrxsmb!SmbCryptoCreateApplicationKey hit!');
    let regs = host.currentThread.Registers.User;
    let app_key_ptr = u64(host.parseInt64(regs.rsp).add(0x30));
    let app_key     = mem_read_array(app_key_ptr, 16);
    ok('ApplicationKey: ' + hex(app_key));
}

function invokeScript() {
    let control = host.namespace.Debugger.Utility.Control;
    // Hook SmbCryptoCreateCipherKeys
    let bp_1 = control.SetBreakpointAtOffset("SmbCryptoCreateCipherKeys", 0, "mrxsmb");
    bp_1.Command = 'dx @$scriptContents.handle_create_cipher_keys(); gc';
    // Hook SmbCryptoCreateApplicationKey
    let bp_2 = control.SetBreakpointAtOffset("SmbCryptoCreateApplicationKey", 107, "mrxsmb");
    bp_2.Command = 'dx @$scriptContents.handle_create_application_key(); gc';
    ok('Press "g" to run the target.');
}
```

Получаем:

```
[+] mrxsmb!SmbCryptoCreateApplicationKey hit!
[+] ApplicationKey: a082f9980639311e0422545662243274
@$scriptContents.handle_create_application_key()
```

Та-да! Мы нашли ключ, который использует PsExec!

# Выводы

Стоит заметить, что ApplicationKey используется только если версия диалекта >= 3, во всех остальных случаях для расшифровки трафика достаточно достать NTLMv2 SessionKey.

Код библиотеки и WinDbg скрипт доступны [тут](https://github.com/archercreat/Panda).

# Референсы

http://davenport.sourceforge.net/ntlm.html

https://sensepost.com/blog/2019/recreating-known-universal-windows-password-backdoors-with-frida/

http://en.verysource.com/code/277230_1/context.cxx.html


---

Конец.
