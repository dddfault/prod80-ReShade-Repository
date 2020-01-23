/*
    Description : PD80 02 Filmic Adaptation for Reshade https://reshade.me/
    Author      : prod80 (Bas Veth)
    License     : MIT, Copyright (c) 2020 prod80

    Additional credits
    - Padraic Hennessy for the logic
      https://placeholderart.wordpress.com/2014/11/21/implementing-a-physically-based-camera-manual-exposure/
    - Padraic Hennessy for the logic
      https://placeholderart.wordpress.com/2014/12/15/implementing-a-physically-based-camera-automatic-exposure/
    - MJP and David Neubelt for the method
      https://github.com/TheRealMJP/BakingLab/blob/master/BakingLab/Exposure.hlsl
      License: MIT, Copyright (c) 2016 MJP
    
    
    MIT License

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    
*/

#include "ReShade.fxh"
#include "ReShadeUI.fxh"

namespace pd80_filmicadaptation
{
    //// UI ELEMENTS ////////////////////////////////////////////////////////////////
    uniform float adj_shoulder <
    	ui_label = "Adjust Highlights";
        ui_category = "Tonemapping";
        ui_type = "slider";
        ui_min = 1.0;
        ui_max = 5.0;
        > = 1.0;
    uniform float adj_linear <
    	ui_label = "Adjust Linearity";
        ui_category = "Tonemapping";
        ui_type = "slider";
        ui_min = 1.0;
        ui_max = 10.0;
        > = 1.0;
    uniform float adj_toe <
    	ui_label = "Adjust Shadows";
        ui_category = "Tonemapping";
        ui_type = "slider";
        ui_min = 1.0;
        ui_max = 5.0;
        > = 1.0;

    //// TEXTURES ///////////////////////////////////////////////////////////////////
    texture texColorBuffer : COLOR;
    texture texLuma { Width = 256; Height = 256; Format = R16F; MipLevels = 8; };
    texture texAvgLuma { Format = R16F; };
    texture texPrevAvgLuma { Format = R16F; };
    //// SAMPLERS ///////////////////////////////////////////////////////////////////
    sampler samplerColor { Texture = texColorBuffer; };
    sampler samplerLuma { Texture = texLuma; };
    sampler samplerAvgLuma { Texture = texAvgLuma; };
    sampler samplerPrevAvgLuma { Texture = texPrevAvgLuma; };
    //// DEFINES ////////////////////////////////////////////////////////////////////
    #define LumCoeff float3(0.212656, 0.715158, 0.072186)
    uniform float Frametime < source = "frametime"; >;
    //// FUNCTIONS //////////////////////////////////////////////////////////////////
    float getLuminance( in float3 x )
    {
        return dot( x, LumCoeff );
    }

    float3 LinearTosRGB( in float3 color )
    {
        float3 x         = color * 12.92f;
        float3 y         = 1.055f * pow( saturate( color ), 1.0f / 2.4f ) - 0.055f;
        float3 clr       = color;
        clr.r            = color.r < 0.0031308f ? x.r : y.r;
        clr.g            = color.g < 0.0031308f ? x.g : y.g;
        clr.b            = color.b < 0.0031308f ? x.b : y.b;
        return clr;
    }

    float3 SRGBToLinear( in float3 color )
    {
        float3 x         = color / 12.92f;
        float3 y         = pow( max(( color + 0.055f ) / 1.055f, 0.0f ), 2.4f );
        float3 clr       = color;
        clr.r            = color.r <= 0.04045f ? x.r : y.r;
        clr.g            = color.g <= 0.04045f ? x.g : y.g;
        clr.b            = color.b <= 0.04045f ? x.b : y.b;
        return clr;
    }

    float3 softlight(float3 c, float3 b) 	{ return b<0.5f ? (2.0f*c*b+c*c*(1.0f-2.0f*b)):(sqrt(c)*(2.0f*b-1.0f)+2.0f*c*(1.0f-b));}

    float3 con( float3 res, float x )
    {
        //softlight
        float3 c = softlight( res.xyz, res.xyz );
        float c1 = 0.0f;
        c1 = x < 0.0f ? c1 = x * 0.5f : c1 = x;
        return lerp( res.xyz, c.xyz, c1 );
    }

    float3 Filmic( in float3 Fc, in float FA, in float FB, in float FC, in float FD, in float FE, in float FF, in float FWhite )
    {
        float3 num       = (( Fc * ( FA * Fc + FC * FB ) + FD * FE ) / ( Fc * ( FA * Fc + FB ) + FD * FF )) - FE / FF;
        float3 denom     = (( FWhite * ( FA * FWhite + FC * FB ) + FD * FE ) / ( FWhite * ( FA * FWhite + FB ) + FD * FF )) - FE / FF;
        return LinearTosRGB( num / denom );
        //return num / denom;
    }

    //// PIXEL SHADERS //////////////////////////////////////////////////////////////
    float PS_WriteLuma(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
    {
        float4 color     = tex2D( samplerColor, texcoord );
        color.xyz        = SRGBToLinear( color.xyz ); // Convert to linear to do avg scene luminosity
        float luma       = getLuminance( color.xyz );
        luma             = max( luma, 0.06f ); // give it a min value so that too dark scenes don't count too much against average
        return log2( luma );
    }

    float PS_AvgLuma(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
    {
        float luma       = tex2Dlod( samplerLuma, float4(0.5f, 0.5f, 0, 8 )).x;
        luma             = exp2( luma );
        float prevluma   = tex2D( samplerPrevAvgLuma, float2( 0.5f, 0.5f )).x;
        float fps        = 1000.0f / Frametime;
        float delay      = fps; //* 0.5f 	
        float avgLuma    = lerp( prevluma, luma, 1.0f / delay );
        return avgLuma;
    }

    float4 PS_Tonemap(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
    {
    	// Filmic operators, most fixed with no GUI
        float A          = 0.65f  * adj_shoulder;
    	float B          = 0.085f * adj_linear;
    	float C          = 1.83f;
    	float D          = 0.55f  * adj_toe;
    	float E          = 0.05f;
    	float F          = 0.57f;
    	float W          = 1.0f; // working in LDR space, white should be 1.0
        float4 color     = tex2D( samplerColor, texcoord );
        float luma       = tex2D( samplerAvgLuma, float2( 0.5f, 0.5f )).x;
        color.xyz        = SRGBToLinear( color.xyz );
        float exp        = lerp( 1.0f, 8.0f, luma ); // Increase Toe when brightness goes up (increase contrast)
        float toe        = max( D * exp, D ); // Increase toe, effect is mild even though there's a potential 8x increase here
        color.xyz        = Filmic( color.xyz, A, B, C, toe, E, F, W );

        return float4( color.xyz, 1.0f );
    }

    float PS_PrevAvgLuma(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
    {
        float avgLuma    = tex2D( samplerAvgLuma, float2( 0.5f, 0.5f )).x;
        return avgLuma;
    }

    //// TECHNIQUES /////////////////////////////////////////////////////////////////
    technique prod80_01_FilmicTonemap
    {
        pass Luma
        {
            VertexShader   = PostProcessVS;
            PixelShader    = PS_WriteLuma;
            RenderTarget   = texLuma;
        }
        pass AvgLuma
        {
            VertexShader   = PostProcessVS;
            PixelShader    = PS_AvgLuma;
            RenderTarget   = texAvgLuma;
        }
        pass Tonemapping
        {
            VertexShader   = PostProcessVS;
            PixelShader    = PS_Tonemap;
        }
        pass PreviousLuma
        {
            VertexShader   = PostProcessVS;
            PixelShader    = PS_PrevAvgLuma;
            RenderTarget   = texPrevAvgLuma;
        }
    }
}