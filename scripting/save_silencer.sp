#pragma semicolon 1

#include <sourcemod>
#include <sdkhooks>

#pragma newdecls required

#if !defined SPPP_COMPILER
	#define decl static
#endif

#define SQL_TABLE_NAME "save_silencer"

#define SQL_CREATE_TABLE \
"CREATE TABLE IF NOT EXISTS `" ... SQL_TABLE_NAME ... "` \
(\
	`accountid` int unsigned NOT NULL, \
	`item_definition` smallint unsigned NOT NULL, \
	`is_silencer` bit NOT NULL DEFAULT 1, \
	PRIMARY KEY (`accountid`, `item_definition`)\
);"

#define SQL_LOAD_DATA \
"SELECT \
	`item_definition`, \
	CAST(`is_silencer` AS int) \
FROM \
	`" ... SQL_TABLE_NAME ... "` \
WHERE \
	`accountid` = %u"

#define SQL_REPLACE_DATA \
"REPLACE INTO `" ... SQL_TABLE_NAME ... "` \
(\
	`accountid`, \
	`item_definition`, \
	`is_silencer`\
) \
VALUES (%u, %u, %u);"

enum CSWeaponMode
{
	Primary_Mode = 0,
	Secondary_Mode,
	WeaponMode_MAX
};

enum struct SilencerData
{
	int  iDefinitionIndex;
	bool bIsSilencer;
}

int       g_iAccountID[MAXPLAYERS + 1],
          m_hActiveWeapon,
          m_bSilencerOn,
          m_weaponMode,
          m_iItemDefinitionIndex;

ArrayList g_hSilencerData[MAXPLAYERS + 1];

Database  g_hDatabase;

public Plugin myinfo =
{
	name = "Save Silencer",
	author = "Wend4r",
	version = "1.0",
	url = "Discord: Wend4r#0001 | VK: vk.com/wend4r"
};

public void OnPluginStart()
{
	m_hActiveWeapon = FindSendPropInfo("CBasePlayer", "m_hActiveWeapon");
	m_bSilencerOn = FindSendPropInfo("CWeaponCSBase", "m_bSilencerOn");		// (type integer) (bits 1) (Unsigned)
	m_weaponMode = FindSendPropInfo("CWeaponCSBase", "m_weaponMode");		// (type integer) (bits 1) (Unsigned)
	m_iItemDefinitionIndex = FindSendPropInfo("CEconEntity", "m_iItemDefinitionIndex");

	HookEvent("silencer_on", OnSilencerEvents);
	HookEvent("silencer_off", OnSilencerEvents);

	ConnectDB();
}

void ConnectDB()
{
	static const char sDatabaseName[] = "save_silencer";

	if(SQL_CheckConfig(sDatabaseName))
	{
		Database.Connect(ConnectToDatabase, sDatabaseName);
	}
	else
	{
		decl char sError[64];

		KeyValues hKV = new KeyValues(NULL_STRING, "driver", "sqlite");

		hKV.SetString("database", sDatabaseName);

		Database hDatabase = SQL_ConnectCustom(hKV, sError, sizeof(sError), false);

		ConnectToDatabase(hDatabase, sError, 0);

		hKV.Close();
	}
}

void ConnectToDatabase(Database hDatabase, const char[] sError, any NULL)
{
	if(sError[0])
	{
		SetFailState("Could not connect to the database - %s", sError);
	}

	(g_hDatabase = hDatabase).Query(SQL_Callback, SQL_CREATE_TABLE, 1, DBPrio_High);
}

void SQL_Callback(Database hDatabase, DBResultSet hResult, const char[] sError, int iData)
{
	if(!hResult)
	{
		LogError("SQL_Callback Error (%i): %s", iData, sError);
		return;
	}

	if(iData & 1)		// SQL_CREATE_TABLE
	{
		decl char sQuery[256];

		Transaction hTransaction = new Transaction();

		for(int i = MaxClients + 1; --i;)
		{
			if(IsClientInGame(i) && !IsFakeClient(i))
			{
				FormatEx(sQuery, sizeof(sQuery), SQL_LOAD_DATA, g_iAccountID[i] = GetSteamAccountID(i));
				hTransaction.AddQuery(sQuery, GetClientUserId(i) << 1);
			}
		}

		g_hDatabase.Execute(hTransaction, SQL_TransactionLoadPlayers, SQL_TransactionFailure, 10);
	}
	else		// SQL_LOAD_DATA
	{
		int iClient = GetClientOfUserId(iData >>> 1);

		if(iClient)
		{
			SQL_LoadPlayer(iClient, hResult);
		}
	}
}

void SQL_CallbackNone(Database hDatabase, DBResultSet hResult, const char[] sError, int iData)
{
	if(!hResult)
	{
		LogError("SQL_Callback Error (%i): %s", iData, sError);
		return;
	}
}

void SQL_TransactionLoadPlayers(Database hDatabase, int iData, int iNumQueries, const DBResultSet[] hResults, const int[] iUserIDs)
{
	for(int i = 0, iClient; i != iNumQueries; i++)
	{
		if((iClient = GetClientOfUserId(iUserIDs[i] >>> 1)))
		{
			SQL_LoadPlayer(iClient, hResults[i]);
		}
	}
}

void SQL_TransactionFailure(Database hDatabase, int iData, int iNumQueries, const char[] sError, int iFailIndex, const any[] iQueryData)
{
	if(sError[0])
	{
		LogError("SQL_TransactionFailure (%i): %s", iData, sError);
	}
}

void SQL_LoadPlayer(const int &iClient, const DBResultSet &hResult)
{
	if(IsClientInGame(iClient) && hResult.HasResults)
	{
		decl SilencerData iSilencerData;

		g_hSilencerData[iClient] = new ArrayList(sizeof(SilencerData));

		// SQL_LOAD_DATA
		while(hResult.FetchRow())
		{
			iSilencerData.iDefinitionIndex = hResult.FetchInt(0);
			iSilencerData.bIsSilencer = hResult.FetchInt(1) != 0;

			// PrintToConsole(iClient, "%N: %i, %i", iClient, iSilencerData.iDefinitionIndex, iSilencerData.bIsSilencer);

			g_hSilencerData[iClient].PushArray(iSilencerData, sizeof(iSilencerData));
		}

		// With the post there is a silencer flicker.
		SDKHook(iClient, SDKHook_WeaponEquip, OnPlayerWeaponEquip);
	}
}

public void OnClientPutInServer(int iClient)
{
	if(!IsFakeClient(iClient))
	{
		decl char sQuery[256];

		FormatEx(sQuery, sizeof(sQuery), SQL_LOAD_DATA, g_iAccountID[iClient] = GetSteamAccountID(iClient));
		g_hDatabase.Query(SQL_Callback, sQuery, GetClientUserId(iClient) << 1);
	}
}

Action OnPlayerWeaponEquip(int iClient, int iEntity)
{
	ArrayList hSilencerData = g_hSilencerData[iClient];

	if(hSilencerData)
	{
		int iIndex = hSilencerData.FindValue(GetEntData(iEntity, m_iItemDefinitionIndex, 2));

		if(iIndex != -1)
		{
			bool bIsSilencer = hSilencerData.Get(iIndex, SilencerData::bIsSilencer);

			SetEntData(iEntity, m_bSilencerOn, hSilencerData.Get(iIndex, SilencerData::bIsSilencer), 1, true);
			SetEntData(iEntity, m_weaponMode, bIsSilencer ? Secondary_Mode : Primary_Mode, 1, true);
		}
	}
}

void OnSilencerEvents(Event hEvent, const char[] sName, bool bDontBroadcast)
{
	int iClient = GetClientOfUserId(hEvent.GetInt("userid"));

	if(iClient)
	{
		int iActiveWeapon = GetEntDataEnt2(iClient, m_hActiveWeapon);

		if(iActiveWeapon != -1)
		{
			int iDefIndex = GetEntData(iActiveWeapon, m_iItemDefinitionIndex, 2);

			decl char sQuery[256];

			FormatEx(sQuery, sizeof(sQuery), SQL_REPLACE_DATA, g_iAccountID[iClient], iDefIndex, sName[10] == 'n' /* Is "silencer_on" or "silencer_off" */ );
			g_hDatabase.Query(SQL_CallbackNone, sQuery, GetClientUserId(iClient));

			ArrayList hSilencerData = g_hSilencerData[iClient];

			if(hSilencerData)
			{
				int iIndex = hSilencerData.FindValue(iDefIndex);

				if(iIndex == -1)
				{
					decl SilencerData iSilencerData;

					iSilencerData.iDefinitionIndex = iDefIndex;
					iSilencerData.bIsSilencer = sName[10] == 'n';

					hSilencerData.PushArray(iSilencerData, sizeof(iSilencerData));
				}
				else
				{
					hSilencerData.Set(iIndex, sName[10] == 'n', SilencerData::bIsSilencer);
				}
			}
		}
	}
}

public void OnClientDisconnect(int iClient)
{
	delete g_hSilencerData[iClient];
}

public void OnPluginEnd()
{
	for(int i = MaxClients + 1; --i;)
	{
		if(IsClientInGame(i))
		{
			OnClientDisconnect(i);
		}
	}
}