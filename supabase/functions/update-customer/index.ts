import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,"Content-Type":"application/json"}});
Deno.serve(async(req)=>{
 if(req.method==="OPTIONS") return new Response("ok",{headers:cors});
 if(req.method!=="POST") return reply({error:"Method not allowed"},405);
 const url=Deno.env.get("SUPABASE_URL")!, anon=Deno.env.get("SUPABASE_ANON_KEY")!, service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
 const token=(req.headers.get("Authorization")||"").replace(/^Bearer\s+/i,"");
 if(!token) return reply({error:"Authentication required"},401);
 const auth=createClient(url,anon,{global:{headers:{Authorization:"Bearer "+token}}});
 const {data:{user:admin},error:authError}=await auth.auth.getUser();
 if(authError||!admin||admin.email!=="admin@citi-login.example.com") return reply({error:"Administrator access required"},403);
 const db=createClient(url,service);
 try{
  const b=await req.json();
  const userId=String(b.userId||""), accountId=String(b.accountId||"");
  const fullName=String(b.fullName||"").trim(), username=String(b.username||"").trim().toLowerCase();
  const accountName=String(b.accountName||"").trim(), accountType=String(b.accountType||"").trim();
  const balance=Number(b.balance), accountNumber=String(b.accountNumber||"").replace(/\D/g,"");
  const email=username+"@citi-login.example.com";
  if(!userId||!accountId||!fullName||!username||!accountName||!accountType||!Number.isFinite(balance)||balance<0) return reply({error:"Complete all required fields with valid values."},400);
  if(!/^[a-z0-9._-]{3,32}$/.test(username)) return reply({error:"Username must be 3–32 characters and use letters, numbers, dots, underscores or hyphens."},400);
  if(accountNumber.length!==4) return reply({error:"Enter exactly the last 4 digits of the account number."},400);
  const {data:target,error:targetError}=await db.auth.admin.getUserById(userId);
  if(targetError||!target.user||target.user.email==="admin@citi-login.example.com") return reply({error:"Customer account was not found."},404);
  const password=String(b.password||"");
  if(password && password.length<8) return reply({error:"New password must contain at least 8 characters."},400);
  const metadata={...(target.user.user_metadata||{}),username,fullName,contactEmail:String(b.email||""),phone:String(b.phone||""),address:String(b.address||""),role:"customer"};
  const authUpdate:Record<string,unknown>={user_metadata:metadata,email};
  if(password) authUpdate.password=password;
  const {error:updateAuthError}=await db.auth.admin.updateUserById(userId,authUpdate);
  if(updateAuthError) return reply({error:updateAuthError.message},400);
  const {data:account,error:accountError}=await db.from("accounts").update({name:accountName,account_type:accountType,account_number_last4:accountNumber,balance}).eq("id",accountId).eq("owner_id",userId).select("id").maybeSingle();
  if(accountError) return reply({error:accountError.message},400);
  if(!account) return reply({error:"The selected account could not be found for this customer."},404);
  return reply({success:true});
 }catch(e){return reply({error:e instanceof Error?e.message:"Unable to update customer"},500);}
});