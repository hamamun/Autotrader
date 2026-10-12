//+------------------------------------------------------------------+
//|                                               OnnxBrain.mqh      |
//|   Optional AI layer: runs a model trained in Python directly     |
//|   inside MT5 via the built in ONNX Runtime (build >= 3620).      |
//|   If the model file is missing the EA keeps working with the     |
//|   rule engine only.                                              |
//+------------------------------------------------------------------+
#ifndef AUTOTRADER_ONNX_BRAIN_MQH
#define AUTOTRADER_ONNX_BRAIN_MQH

#include "Types.mqh"

#if AUTOTRADER_USE_ONNX

class CAtOnnxBrain
  {
private:
   long     m_handle;
   string   m_file;
   bool     m_ready;
   int      m_in_count;
   int      m_out_count;

public:
   CAtOnnxBrain() { m_handle=INVALID_HANDLE; m_ready=false; m_in_count=0; m_out_count=0; m_file=""; }

   string   File()  const { return(m_file); }
   bool     Ready() const { return(m_ready); }

   bool     Load(const string file)
     {
      m_file  = file;
      m_ready = false;
      if(m_handle!=INVALID_HANDLE)
        {
         OnnxRelease(m_handle);
         m_handle=INVALID_HANDLE;
        }
      if(!FileIsExist(file,FILE_COMMON))
        {
         PrintFormat("[Autotrader] ONNX model '%s' not found in MQL5\\Files\\Common - rule engine only.",file);
         return(false);
        }
      m_handle = OnnxCreate(file,ONNX_COMMON_FOLDER);
      if(m_handle==INVALID_HANDLE)
        {
         PrintFormat("[Autotrader] OnnxCreate failed (%d)",GetLastError());
         return(false);
        }
      const long shape[] = {1,AT_FEATURE_COUNT};
      if(!OnnxSetInputShape(m_handle,0,shape))
        {
         PrintFormat("[Autotrader] OnnxSetInputShape failed (%d)",GetLastError());
         OnnxRelease(m_handle);
         m_handle=INVALID_HANDLE;
         return(false);
        }
      const long oshape[] = {1,3};   // P(up), P(hold), P(down)
      OnnxSetOutputShape(m_handle,0,oshape);

      m_in_count  = (int)OnnxGetInputCount(m_handle);
      m_out_count = (int)OnnxGetOutputCount(m_handle);
      m_ready     = true;
      PrintFormat("[Autotrader] ONNX model loaded: %s (in=%d out=%d)",file,m_in_count,m_out_count);
      return(true);
     }

   void     Release()
     {
      if(m_handle!=INVALID_HANDLE)
        {
         OnnxRelease(m_handle);
         m_handle=INVALID_HANDLE;
        }
      m_ready=false;
     }

   //--- returns false when the model cannot be used
   bool     Predict(const double &features[],double &p_buy,double &p_hold,double &p_sell)
     {
      p_buy=p_hold=p_sell=0.0;
      if(!m_ready || ArraySize(features)!=AT_FEATURE_COUNT)
         return(false);

      //--- model expects a 2D tensor [1, N]
      double in[1][AT_FEATURE_COUNT];
      for(int i=0;i<AT_FEATURE_COUNT;i++)
         in[0][i]=features[i];

      double out[1][3];
      if(!OnnxRun(m_handle,0,in,out))   // 0 = ONNX_DEFAULT, works on older builds
        {
         PrintFormat("[Autotrader] OnnxRun failed (%d)",GetLastError());
         return(false);
        }
      p_buy  = out[0][0];
      p_hold = out[0][1];
      p_sell = out[0][2];
      return(true);
     }
  };

#else   // ONNX disabled at compile time

class CAtOnnxBrain
  {
public:
   bool   Load(const string file) { return(false); }
   void   Release()               {}
   bool   Ready()           const { return(false); }
   string File()            const { return(""); }
   bool   Predict(const double &f[],double &b,double &h,double &s) { b=h=s=0.0; return(false); }
  };

#endif  // AUTOTRADER_USE_ONNX

#endif  // AUTOTRADER_ONNX_BRAIN_MQH
//+------------------------------------------------------------------+
