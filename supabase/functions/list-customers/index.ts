import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,"Content-Type":"application/json"}});
Deno.serve(async(req)=>{
 if(req.method==="OPTIONS") return new Response("ok",{headers:cors});
 if(req.method!=="POST") return reply({error:"Method not allowed"},405);
 const url=Deno.env.get("SUPABASE_URL")!, anon=Deno.env.get("SUPABASE_ANON_KEY")!, service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
 const token=(req.headers.get("Authorization")||"").replace(/^Bearer\s+/i,"");
 const auth=createClient(url,anon,{global:{headers:{Authorization:"Bearer "+token}}});
 const {data:{user:admin},error}=await auth.auth.getUser();
 if(error||!admin||admin.email!=="admin@citi-login.example.com") return reply({error:"Administrator access required"},403);
 const db=createClient(url,service);
 try{
  const [{data:users,error:userError},{data:accounts,error:accountError}]=await Promise.all([db.auth.admin.listUsers({page:1,perPage:1000}),db.from("accounts").select("id,owner_id,name,account_type,account_number_last4,balance,created_at").order("created_at",{ascending:false})]);
  if(userError) throw userError;if(accountError) throw accountError;
  const customers=(users.users||[]).filter(u=>u.email?.endsWith("@citi-login.example.com")&&u.email!=="admin@citi-login.example.com").map(u=>{
   const a=(accounts||[]).filter(x=>x.owner_id===u.id);
   return {id:u.id,fullName:u.user_metadata?.fullName||u.user_metadata?.username||"Customer",username:u.user_metadata?.username||u.email?.split("@")[0],email:u.user_metadata?.contactEmail||"",phone:u.user_metadata?.phone||"",address:u.user_metadata?.address||"",createdAt:u.created_at,accounts:a.map(x=>({id:x.id,name:x.name,type:x.account_type,number:x.account_number_last4,balance:Number(x.balance)}))};
  });
  return reply({customers});
 }catch(e){return reply({error:e instanceof Error?e.message:"Unable to load customers"},500);}
});