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
 try {
  const b=await req.json();
  const fullName=String(b.fullName||"").trim(), username=String(b.username||"").trim().toLowerCase(), password=String(b.password||"");
  const accountName=String(b.accountName||"").trim(), accountType=String(b.accountType||"").trim(), balance=Number(b.openingBalance);
  if(!fullName||!username||!accountName||!accountType||password.length<8||!Number.isFinite(balance)||balance<0) return reply({error:"Complete all required fields and use a password of at least 8 characters."},400);
  if(!/^[a-z0-9._-]{3,32}$/.test(username)) return reply({error:"Username must be 3–32 characters and use letters, numbers, dots, underscores or hyphens."},400);
  const accountNumber=String(b.accountNumber||"").replace(/\D/g,"");
  if(accountNumber && accountNumber.length<4) return reply({error:"Account number must contain at least 4 digits."},400);
  const email=username+"@citi-login.example.com";
  const {data:created,error:createError}=await db.auth.admin.createUser({email,password,email_confirm:true,user_metadata:{username,fullName,contactEmail:String(b.email||""),phone:String(b.phone||""),address:String(b.address||""),role:"customer"}});
  if(createError) return reply({error:createError.message},400);
  const digits=accountNumber || (String(Date.now())+String(Math.floor(Math.random()*10000))).slice(-12);
  const {data:account,error:accountError}=await db.from("accounts").insert({owner_id:created.user.id,name:accountName,account_type:accountType,account_number_last4:digits.slice(-4),balance}).select("*").single();
  if(accountError){await db.auth.admin.deleteUser(created.user.id);return reply({error:"Customer login was not saved: "+accountError.message},400);}
  return reply({success:true,customer:{id:created.user.id,fullName,username,email:String(b.email||""),phone:String(b.phone||""),address:String(b.address||""),accountName:account.name,accountType:account.account_type,accountNumberLast4:account.account_number_last4,balance:Number(account.balance),status:"Active"}},201);
 } catch(e){return reply({error:e instanceof Error?e.message:"Unexpected error"},500);}
});