Shader "YmneShader/CelShading"
{
    Properties
    {
        [Header(Base Colors)]
        _MainTex ("Texture", 2D) = "white" {}
        _Color ("Albedo Color", Color) = (1,1,1,1)
        [Toggle] _UseTexture ("Use Texture", Float) = 1
        _Cutoff ("Alpha Cutoff", Range(0.0, 1.0)) = 0.5

        [Header(Shading)]
        [Toggle] _UseHardEdgeShadow ("Use Single Shadow Threshold", Float) = 1.0
        _ShadowThreshold ("Shadow Threshold", Range(0, 1)) = 0.5
        _ShadowSteps ("Shadow Steps", Range(1, 10)) = 3
        _ShadowColor ("Shadow Color", Color) = (0.3,0.3,0.3,1)
        _MinLight ("Minimum Light (Ambient)", Range(0,1)) = 0.1
        _SpecularSize ("Specular Size", Range(0,1)) = 0.1
        _SpecularColor ("Specular Color", Color) = (1,1,1,1)

        [Header(Subsurface Scattering)]
        [Toggle] _UseSSS("Enable Subsurface Scattering", Float) = 1.0
        _SubsurfaceColor ("Subsurface Color", Color) = (1, 0.5, 0.4, 1)
        _SubsurfaceAmount ("Subsurface Amount", Range(0, 10)) = 1.0
        _SubsurfaceFalloff ("Subsurface Falloff", Range(1, 8)) = 2.0

        [Header(Rim Light)]
        [Toggle] _UseRimLight("Enable Rim Light", Float) = 1.0
        [Toggle] _RimInShadowsOnly ("Only In Shadows", Float) = 1.0
        _RimColor ("Rim Color", Color) = (0.8, 0.8, 1.0, 1)
        _RimThreshold ("Rim Threshold", Range(0, 1)) = 0.7
        _RimIntensity ("Rim Intensity", Range(0, 10)) = 1.5

        [Header(Double Sided)]
        [Toggle] _DoubleSided ("Double Sided", Float) = 0
        _BackfaceColor ("Backface Color", Color) = (0.8,0.8,1,1)
    }

    SubShader
    {
        Tags { "RenderType"="TransparentCutout" "Queue"="AlphaTest" }
        LOD 200

        // ==================================================================================================
        // Pass 1: ForwardBase
        // Handles main directional light, ambient light, and all primary effects.
        // ==================================================================================================
        Pass
        {
            Tags { "LightMode" = "ForwardBase" }
            Cull Back

            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_fwdbase
            #pragma multi_compile_fog
            #include "UnityCG.cginc"
            #include "Lighting.cginc"

            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv : TEXCOORD0;
                float3 normal : NORMAL;
            };

            struct v2f
            {
                float2 uv : TEXCOORD0;
                float4 pos : SV_POSITION;
                float3 worldNormal : TEXCOORD1;
                float3 worldPos : TEXCOORD2;
                UNITY_FOG_COORDS(3)
            };

            sampler2D _MainTex;
            float4 _MainTex_ST;
            fixed4 _Color, _ShadowColor, _SpecularColor, _SubsurfaceColor, _RimColor, _BackfaceColor;
            float _UseTexture, _Cutoff, _UseHardEdgeShadow, _ShadowThreshold, _ShadowSteps, _MinLight;
            float _SpecularSize, _UseSSS, _SubsurfaceAmount, _SubsurfaceFalloff, _UseRimLight;
            float _RimInShadowsOnly, _RimThreshold, _RimIntensity, _DoubleSided;

            v2f vert (appdata v)
            {
                v2f o;
                o.pos = UnityObjectToClipPos(v.vertex);
                o.uv = TRANSFORM_TEX(v.uv, _MainTex);
                o.worldNormal = UnityObjectToWorldNormal(v.normal);
                o.worldPos = mul(unity_ObjectToWorld, v.vertex).xyz;
                UNITY_TRANSFER_FOG(o,o.pos);
                return o;
            }

            fixed4 frag (v2f i) : SV_Target
            {
                // 1. Albedo & Alpha Clip
                fixed4 albedo = _UseTexture ? tex2D(_MainTex, i.uv) * _Color : _Color;
                clip(albedo.a - _Cutoff);

                // 2. Vector Setup
                float3 worldNormal = normalize(i.worldNormal);
                float3 lightDir = normalize(_WorldSpaceLightPos0.xyz);
                float3 viewDir = normalize(_WorldSpaceCameraPos.xyz - i.worldPos.xyz);

                // 3. Lighting Calculations
                float NdotL = dot(worldNormal, lightDir);

                // a) Cel Shading
                float cel;
                if (_UseHardEdgeShadow > 0.5)
                {
                    cel = step(_ShadowThreshold, saturate(NdotL));
                }
                else
                {
                    cel = floor(saturate(NdotL) * _ShadowSteps) / (_ShadowSteps - 0.5);
                }
                fixed3 directLighting = lerp(_ShadowColor.rgb, _LightColor0.rgb, cel);

                // b) Simple Subsurface-Scattering
                if (_UseSSS > 0.5)
                {
                    float sssWrap = dot(worldNormal, lightDir) * 0.5 + 0.5;
                    float sssMask = saturate(1.0 - saturate(NdotL));
                    fixed3 sssContrib = _SubsurfaceColor.rgb * _LightColor0.rgb * pow(sssWrap, _SubsurfaceFalloff) * sssMask * _SubsurfaceAmount;
                    directLighting += sssContrib;
                }

                // c) Specular Highlights
                float3 halfVec = normalize(lightDir + viewDir);
                float NdotH = saturate(dot(worldNormal, halfVec));
                float specular = step(1.0 - _SpecularSize, NdotH) * _SpecularColor.a;
                directLighting += _SpecularColor.rgb * specular;

                // d) Rim Light
                fixed3 rimLight = fixed3(0,0,0);
                if (_UseRimLight > 0.5)
                {
                    float shadowMask = cel < 0.01 ? 1.0 : 0.0;
                    float finalMask = lerp(1.0, shadowMask, _RimInShadowsOnly);
                    
                    float NdotV = 1.0 - saturate(dot(worldNormal, viewDir));
                    float rim = step(_RimThreshold, NdotV);
                    
                    rimLight = _RimColor.rgb * rim * finalMask * _RimIntensity;
                }

                // e) Ambient Light
                fixed3 indirectLighting = ShadeSH9(float4(worldNormal, 1));
                indirectLighting = max(indirectLighting, _MinLight);

                // 4. Final Combination
                fixed3 finalLighting = directLighting + indirectLighting + rimLight;
                fixed4 col;
                col.rgb = albedo.rgb * finalLighting;
                col.a = albedo.a;

                UNITY_APPLY_FOG(i.fogCoord, col);
                return col;
            }
            ENDCG
        }

        // ==================================================================================================
        // Pass 2: ForwardAdd
        // Handles additional lights. (point, spot, etc.)
        // ==================================================================================================
        Pass
        {
            Tags { "LightMode" = "ForwardAdd" }
            Blend One One
            Cull Back

            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_fwdadd_fullshadows
            #pragma multi_compile_fog
            #include "UnityCG.cginc"
            #include "Lighting.cginc"
            #include "AutoLight.cginc"
            
            struct appdata { float4 vertex : POSITION; float2 uv : TEXCOORD0; float3 normal : NORMAL; };
            struct v2f { float2 uv : TEXCOORD0; float4 pos : SV_POSITION; float3 worldNormal : TEXCOORD1; float3 worldPos : TEXCOORD2; UNITY_FOG_COORDS(3) UNITY_LIGHTING_COORDS(4, 5) };
            sampler2D _MainTex; float4 _MainTex_ST; fixed4 _Color, _SpecularColor;
            float _UseTexture, _Cutoff, _UseHardEdgeShadow, _ShadowThreshold, _ShadowSteps, _SpecularSize;

            v2f vert (appdata v)
            {
                v2f o;
                o.pos = UnityObjectToClipPos(v.vertex);
                o.uv = TRANSFORM_TEX(v.uv, _MainTex);
                o.worldNormal = UnityObjectToWorldNormal(v.normal);
                o.worldPos = mul(unity_ObjectToWorld, v.vertex).xyz;
                UNITY_TRANSFER_FOG(o,o.pos);
                UNITY_TRANSFER_LIGHTING(o, v.vertex);
                return o;
            }

            fixed4 frag (v2f i) : SV_Target
            {
                fixed4 albedo = _UseTexture ? tex2D(_MainTex, i.uv) * _Color : _Color;
                clip(albedo.a - _Cutoff);
                
                float3 lightDir = normalize(_WorldSpaceLightPos0.xyz - i.worldPos.xyz * _WorldSpaceLightPos0.w);
                float3 worldNormal = normalize(i.worldNormal);
                float NdotL = dot(worldNormal, lightDir);
                
                UNITY_LIGHT_ATTENUATION(atten, i, i.worldPos);

                float cel;
                if (_UseHardEdgeShadow > 0.5) { cel = step(_ShadowThreshold, saturate(NdotL)); }
                else { cel = floor(saturate(NdotL) * _ShadowSteps) / (_ShadowSteps - 0.5); }
                fixed3 lighting = _LightColor0.rgb * cel;
                
                float3 viewDir = normalize(_WorldSpaceCameraPos.xyz - i.worldPos.xyz);
                float3 halfVec = normalize(lightDir + viewDir);
                float NdotH = saturate(dot(worldNormal, halfVec));
                float specular = step(1.0 - _SpecularSize, NdotH) * _SpecularColor.a;
                lighting += _LightColor0.rgb * _SpecularColor.rgb * specular;
                
                fixed4 col;
                col.rgb = albedo.rgb * lighting * atten;
                col.a = albedo.a;
                
                UNITY_APPLY_FOG_COLOR(i.fogCoord, col, fixed4(0,0,0,0));
                return col;
            }
            ENDCG
        }

        // ==================================================================================================
        // Pass 3: Backface
        // Renders backfaces with a solid color.
        // ==================================================================================================
        Pass
        {
            Cull Front
            ZWrite Off

            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_fog
            #include "UnityCG.cginc"

            struct appdata { float4 vertex : POSITION; };
            struct v2f { float4 pos : SV_POSITION; UNITY_FOG_COORDS(0) };
            fixed4 _BackfaceColor; float _DoubleSided, _MinLight;

            v2f vert (appdata v) { v2f o; o.pos = UnityObjectToClipPos(v.vertex); UNITY_TRANSFER_FOG(o,o.pos); return o; }
            fixed4 frag (v2f i) : SV_Target
            {
                clip(_DoubleSided - 0.5);
                fixed4 col = _BackfaceColor;
                col.rgb = max(col.rgb, _MinLight);
                UNITY_APPLY_FOG(i.fogCoord, col);
                return col;
            }
            ENDCG
        }
    }
    FallBack "Transparent/Cutout/VertexLit"
}